package main

import "core:c"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import os2 "core:os/os2"
import "core:strings"
import "core:thread"
import "core:sys/posix"
import "base:runtime"

foreign import cli_libc "system:System.framework"
foreign cli_libc {
	flock :: proc "c" (fd, operation: c.int) -> c.int ---
	close :: proc "c" (fd: c.int) -> c.int ---
}

CLI_LOCK_EX :: 2
CLI_LOCK_NB :: 4
CLI_LOCK_UN :: 8
CLI_MODE_USER_READ_WRITE :: posix.mode_t{.IRUSR, .IWUSR}

CLI_Library_Owner :: struct {
	file: ^os2.File,
	held: bool,
}

CLI_IPC_Response :: struct {
	exit_code: CLI_Exit,
	output: string,
}

CLI_IPC_Work :: struct {
	request: CLI_Request,
	result: CLI_Result,
}

CLI_IPC_State :: struct {
	thread: ^thread.Thread,
	listen_fd: posix.FD,
	running: bool,
}

cli_library_owner: CLI_Library_Owner
cli_ipc_state: CLI_IPC_State
cli_ipc_work: ^CLI_IPC_Work

cli_lock_path :: proc() -> string {
	return fmt.tprintf("%s/library.lock", app_support_dir())
}

cli_socket_path :: proc() -> string {
	return fmt.tprintf("%s/control.sock", app_support_dir())
}

cli_library_try_acquire :: proc() -> bool {
	if cli_library_owner.held {return true}
	os.make_directory(app_support_dir())
	file, open_error := os2.open(cli_lock_path(), {.Read, .Write, .Create})
	if open_error != nil {return false}
	if posix.fchmod(posix.FD(os2.fd(file)), CLI_MODE_USER_READ_WRITE) != .OK {
		_ = os2.close(file)
		return false
	}
	fd := c.int(os2.fd(file))
	if flock(fd, CLI_LOCK_EX|CLI_LOCK_NB) != 0 {
		_ = os2.close(file)
		return false
	}
	cli_library_owner = CLI_Library_Owner{file=file, held=true}
	return true
}

cli_library_release :: proc() {
	if !cli_library_owner.held {return}
	_ = flock(c.int(os2.fd(cli_library_owner.file)), CLI_LOCK_UN)
	_ = os2.close(cli_library_owner.file)
	cli_library_owner = {}
}

cli_socket_address :: proc(path: string) -> (posix.sockaddr_un, bool) {
	address: posix.sockaddr_un
	if len(path) == 0 || len(path) >= len(address.sun_path) {return address, false}
	address.sun_len = u8(size_of(address))
	address.sun_family = .UNIX
	for byte, index in path {address.sun_path[index] = c.char(byte)}
	return address, true
}

cli_socket_send_all :: proc(fd: posix.FD, bytes: []u8) -> bool {
	sent := 0
	for sent < len(bytes) {
		count := posix.send(fd, raw_data(bytes[sent:]), c.size_t(int(len(bytes))-sent), {.NOSIGNAL})
		if count <= 0 {return false}
		sent += int(count)
	}
	return true
}

cli_socket_receive_all :: proc(fd: posix.FD, allocator := context.allocator) -> ([]u8, bool) {
	contents := make([dynamic]u8, allocator)
	success := false
	defer if !success {delete(contents)}
	buffer: [16*1024]u8
	for {
		count := posix.recv(fd, raw_data(buffer[:]), c.size_t(len(buffer)), {})
		if count < 0 {return nil, false}
		if count == 0 {break}
		append(&contents, ..buffer[:int(count)])
	}
	success = true
	return contents[:], true
}

cli_ipc_request_destroy :: proc(request: ^CLI_Request) {
	delete(request.url)
	delete(request.source_id)
	delete(request.from_segment)
	delete(request.to_segment)
	delete(request.name)
	delete(request.baseline_path)
	delete(request.scenario)
	request^ = {}
}

on_cli_ipc_request :: proc "c" (self: Id, command: Sel, sender: Id) {
	context = runtime.default_context()
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	if cli_ipc_work == nil {return}
	cli_ipc_work.result = cli_execute(cli_ipc_work.request)
	if cli_command_mutates_library(cli_ipc_work.request.command) {
		refresh_sources()
		refresh_exercises()
		ui.needs_redraw = true
	}
}

cli_ipc_serve_connection :: proc(fd: posix.FD) {
	request_bytes, read_ok := cli_socket_receive_all(fd, context.temp_allocator)
	if !read_ok {return}
	request: CLI_Request
	if decode_error := json.unmarshal(request_bytes, &request); decode_error != nil {return}
	defer cli_ipc_request_destroy(&request)
	work := CLI_IPC_Work{request=request}
	cli_ipc_work = &work
	msg_void_sel_id_b(
		state.delegate_target,
		sel_registerName("performSelectorOnMainThread:withObject:waitUntilDone:"),
		sel_registerName("cliRequest:"),
		nil,
		true,
	)
	cli_ipc_work = nil
	defer delete(work.result.output)
	wire_bytes, encode_error := json.marshal(CLI_IPC_Response{exit_code=work.result.exit_code, output=work.result.output})
	if encode_error != nil {return}
	defer delete(wire_bytes)
	_ = cli_socket_send_all(fd, wire_bytes)
}

cli_ipc_server_worker :: proc(t: ^thread.Thread) {
	context = runtime.default_context()
	for cli_ipc_state.running {
		client := posix.accept(cli_ipc_state.listen_fd, nil, nil)
		if client < 0 {
			if !cli_ipc_state.running {break}
			continue
		}
		{
			runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
			cli_ipc_serve_connection(client)
		}
		_ = close(c.int(client))
	}
}

cli_ipc_server_start :: proc() -> bool {
	if cli_ipc_state.running {return true}
	path := cli_socket_path()
	address, address_ok := cli_socket_address(path)
	if !address_ok {return false}
	fd := posix.socket(.UNIX, .STREAM)
	if fd < 0 {return false}
	started := false
	defer if !started {
		_ = close(c.int(fd))
		_ = os.remove(path)
	}
	_ = os.remove(path)
	if posix.bind(fd, cast(^posix.sockaddr)&address, posix.socklen_t(size_of(address))) != .OK {return false}
	c_path := strings.clone_to_cstring(path)
	mode_set := posix.chmod(c_path, CLI_MODE_USER_READ_WRITE) == .OK
	delete(c_path)
	if !mode_set {return false}
	if posix.listen(fd, 4) != .OK {return false}
	worker := thread.create(cli_ipc_server_worker)
	if worker == nil {return false}
	cli_ipc_state = CLI_IPC_State{thread=worker, listen_fd=fd, running=true}
	thread.start(worker)
	started = true
	return true
}

cli_ipc_server_stop :: proc() {
	if !cli_ipc_state.running {return}
	cli_ipc_state.running = false
	_ = posix.shutdown(cli_ipc_state.listen_fd, .RDWR)
	_ = close(c.int(cli_ipc_state.listen_fd))
	if cli_ipc_state.thread != nil {
		thread.join(cli_ipc_state.thread)
		thread.destroy(cli_ipc_state.thread)
	}
	_ = os.remove(cli_socket_path())
	cli_ipc_state = {}
}

cli_ipc_try_request :: proc(request: CLI_Request) -> (CLI_Result, bool) {
	path := cli_socket_path()
	address, address_ok := cli_socket_address(path)
	if !address_ok {return {}, false}
	fd := posix.socket(.UNIX, .STREAM)
	if fd < 0 {return {}, false}
	defer close(c.int(fd))
	if posix.connect(fd, cast(^posix.sockaddr)&address, posix.socklen_t(size_of(address))) != .OK {
		return {}, false
	}
	request_bytes, encode_error := json.marshal(request)
	if encode_error != nil {return cli_error(request.command, .Storage, "internal_error", "Unable to encode the app request"), true}
	defer delete(request_bytes)
	if !cli_socket_send_all(fd, request_bytes) {return cli_error(request.command, .Storage, "ipc_failed", "Unable to send the request to the running app"), true}
	_ = posix.shutdown(fd, .WR)
	response_bytes, read_ok := cli_socket_receive_all(fd, context.temp_allocator)
	if !read_ok {return cli_error(request.command, .Storage, "ipc_failed", "Unable to read the running app response"), true}
	response: CLI_IPC_Response
	if decode_error := json.unmarshal(response_bytes, &response); decode_error != nil {return cli_error(request.command, .Storage, "ipc_failed", "The running app returned an invalid response"), true}
	return CLI_Result{output=response.output, exit_code=response.exit_code}, true
}
