package main

// palm-modules --selftest: the glob, the name rules and alias lookup, on a
// made-up index. No modules are loaded and nothing on the host is read.

import "core:fmt"

selftest :: proc() -> int {
	bad := 0
	check :: proc(bad: ^int, cond: bool, what: string) {
		if !cond {
			fmt.eprintfln("FAIL %s", what)
			bad^ += 1
		}
	}

	check(&bad, glob("pci:v00008086d*sv*sd*bc03sc*i*", "pci:v00008086d0000A7A0sv00001028sd00000B14bc03sc00i00"), "glob: Intel display class")
	check(&bad, !glob("pci:v00008086d*sv*sd*bc03sc*i*", "pci:v00001002d00001681sv0sd0bc03sc00i00"), "glob: other vendor")
	check(&bad, glob("usb:v0BDAp8153d[0-2]*dc*", "usb:v0BDAp8153d1000dc00"), "glob: range")
	check(&bad, !glob("usb:v0BDAp8153d[0-2]*dc*", "usb:v0BDAp8153d3000dc00"), "glob: outside range")
	check(&bad, glob("a[!b]c", "axc") && !glob("a[!b]c", "abc"), "glob: negated set")
	check(&bad, glob("*", "") && glob("a*b*c", "aXbYc") && !glob("a*b*c", "aXbY"), "glob: stars")
	check(&bad, glob("x?z", "xyz") && !glob("x?z", "xz"), "glob: ?")

	check(&bad, module_name("kernel/sound/hda/snd-hda-intel.ko.zst") == "snd_hda_intel", "name from a path")
	check(&bad, module_name("snd-hda-intel") == "snd_hda_intel", "dashes are underscores")
	check(&bad, module_name("kernel/fs/ext4/ext4.ko") == "ext4", "plain .ko")

	ix: Index
	ix.dir = "/nonexistent"
	ix.paths["i915"] = "kernel/drivers/gpu/drm/i915/i915.ko.zst"
	ix.paths["e1000e"] = "kernel/drivers/net/ethernet/intel/e1000e/e1000e.ko.zst"
	ix.paths["nouveau"] = "kernel/drivers/gpu/drm/nouveau/nouveau.ko.zst"
	ix.builtin["ext4"] = true
	add_alias(&ix, "pci:v00008086d0000A7A0sv*sd*bc03sc*i*", "i915")
	add_alias(&ix, "pci:v000010DEd*sv*sd*bc03sc*i*", "nouveau")
	add_alias(&ix, "pci:v00008086d000015BCsv*sd*bc*sc*i*", "e1000e")
	add_alias(&ix, "net-pf-10", "e1000e")
	add_alias(&ix, "*:pattern-with-star-key", "e1000e")

	mods, builtin := lookup(&ix, "pci:v00008086d0000A7A0sv00001028sd00000B14bc03sc00i00")
	check(&bad, len(mods) == 1 && mods[0] == "i915" && !builtin, "lookup: modalias")
	mods, builtin = lookup(&ix, "ext4")
	check(&bad, len(mods) == 0 && builtin, "lookup: built in")
	mods, _ = lookup(&ix, "e1000e")
	check(&bad, len(mods) == 1 && mods[0] == "e1000e", "lookup: by name")
	mods, _ = lookup(&ix, "net-pf-10")
	check(&bad, len(mods) == 1 && mods[0] == "e1000e", "lookup: plain alias")
	mods, _ = lookup(&ix, "usb:pattern-with-star-key")
	check(&bad, len(mods) == 1, "lookup: wildcard key is always searched")
	mods, _ = lookup(&ix, "pci:v00001234d0000sv0sd0bc00sc00i00")
	check(&bad, len(mods) == 0, "lookup: no match")

	parse_conf_line(&ix, "blacklist nouveau")
	parse_conf_line(&ix, "options snd-hda-intel power_save=1")
	parse_conf_line(&ix, "  # a comment")
	check(&bad, "nouveau" in ix.blacklist, "modprobe.d: blacklist")
	check(&bad, ix.options["snd_hda_intel"] == "power_save=1", "modprobe.d: options")
	parse_softdep(&ix, "softdep snd_hda_intel pre: snd-intel-dspcfg post: snd_hda_codec_hdmi")
	check(&bad, len(ix.pre["snd_hda_intel"]) == 1 && ix.pre["snd_hda_intel"][0] == "snd_intel_dspcfg", "softdep pre")
	check(&bad, len(ix.post["snd_hda_intel"]) == 1, "softdep post")

	if bad == 0 {fmt.println("palm-modules selftest: ok")}
	return 1 if bad > 0 else 0
}
