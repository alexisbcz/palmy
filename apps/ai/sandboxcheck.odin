package main

// `ai sandbox-check`: this binary, confined exactly as `ai agent` is, on a
// throwaway home that holds two identities, the person's token store and an
// SSH key — then probed (cloud/assistant/sandbox/probe.odin). The real tool
// directory is used, so the check covers what this installation would run.

import "core:fmt"
import "core:net"
import "core:os"
import "core:strings"

@(private = "file")
put :: proc(path, text: string) {
	os.make_directory_all(path[:strings.last_index_byte(path, '/')], os.perm_number(0o700))
	_ = os.write_entire_file(path, transmute([]u8)text, os.perm_number(0o600))
}

sandbox_check_run :: proc() -> (out: string, err: string) {
	base := os.get_env("TMPDIR", context.temp_allocator)
	if base == "" {base = "/tmp"}
	home := fmt.tprintf("%s/palm-ai-sandbox.%d", base, os.get_pid())
	defer os.remove_all(home)
	own, other := "camille.roux", "camille"
	put(fmt.tprintf("%s/Drive/%s/invoice.txt", home, own), "Halden invoice\n")
	put(fmt.tprintf("%s/Notes/%s/meeting.md", home, own), "# Roadmap\n")
	put(fmt.tprintf("%s/Drive/%s/tax-return.txt", home, other), "PERSONAL-CANARY-7731\n")
	put(fmt.tprintf("%s/Notes/%s/diary.md", home, other), "PERSONAL-CANARY-7731\n")
	put(fmt.tprintf("%s/.local/share/palm/assistant/%s/session.json", home, other), "{}\n")
	put(fmt.tprintf("%s/.local/share/palm/cloud/session.json", home), "{}\n")
	put(fmt.tprintf("%s/.local/share/palm/cloud/scoped/%s.json", home, other), "{}\n")
	put(fmt.tprintf("%s/.ssh/id_ed25519", home), "-----BEGIN OPENSSH PRIVATE KEY-----\n")
	put(fmt.tprintf("%s/.local/share/palm/index/%s/manifest", home, own), "own index\n")
	put(fmt.tprintf("%s/.local/share/palm/index/%s/manifest", home, other), "PERSONAL-CANARY-7731\n")

	tools := tools_dir()
	tool := ""
	entries, _ := os.read_all_directory_by_path(tools, context.temp_allocator)
	for e in entries {
		if e.type != .Directory && !strings.has_suffix(e.name, ".log") {
			tool = fmt.tprintf("%s/%s", tools, e.name)
			break
		}
	}
	if tool == "" {return "", fmt.tprintf("no tools in %s", tools)}

	l1, e1 := net.listen_tcp(net.Endpoint{address = net.IP4_Loopback, port = 0})
	l2, e2 := net.listen_tcp(net.Endpoint{address = net.IP4_Loopback, port = 0})
	if e1 != nil || e2 != nil {return "", "could not listen on loopback"}
	defer net.close(l1)
	defer net.close(l2)
	ep1, _ := net.bound_endpoint(l1)
	ep2, _ := net.bound_endpoint(l2)

	self, _ := os.get_executable_path(context.temp_allocator)
	state, stdout, stderr, perr := os.process_exec({
		command = {self, "sandbox-probe", "--handle", own, "--other", other, "--tools", tools, "--tool", tool,
			"--open-port", fmt.tprintf("%d", ep1.port), "--shut-port", fmt.tprintf("%d", ep2.port),
			"--parent", fmt.tprintf("%d", os.get_pid())},
		env = {fmt.tprintf("HOME=%s", home), "PATH=/usr/bin"},
	}, context.temp_allocator)
	if perr != nil {return "", fmt.tprintf("could not start the probe (%v)", perr)}
	_ = state
	text := strings.trim_space(string(stdout))
	if text == "" {return "", strings.trim_space(string(stderr))}
	return strings.clone(text), ""
}
