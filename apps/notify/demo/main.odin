// The smallest app that notifies: what adopting apps/kit/notify.odin takes.
//
//	notify-demo mail          a new mail, as Mail would send it
//	notify-demo call          an incoming call, waiting for Answer or Decline
//	notify-demo withdraw      the call was answered on another device
//
// Build: odin build apps/notify/demo -collection:kit=apps/kit \
//            -collection:palmy=palmy -collection:shadcn=shadcn
//
// Run it inside an identity (PALM_IDENTITY=camille.roux) and the
// notification is that identity's; nothing in the code says which.
package main

import "core:fmt"
import "core:os"
import "core:time"
import kit "kit:."

main :: proc() {
	what := len(os.args) > 1 ? os.args[1] : "mail"
	switch what {
	case "mail":
		// The key names the message, not the notification: Home announcing
		// the same message would be an update, not a second toast.
		r := kit.notify({
			key = "mail:<q4-roadmap@northwind.coop>",
			app = "mail",
			class = .Person,
			category = "email.arrived",
			title = "Priya Shah",
			body = "Q4 roadmap: can you sign off by Friday?",
			link = "mail open <q4-roadmap@northwind.coop>",
			actions = {{key = "reply", label = "Reply", run = "mail reply <q4-roadmap@northwind.coop>"}},
		})
		fmt.printfln("mail: ok=%v id=%d delivery=%s why=%q", r.ok, r.id, r.delivery, r.why)

	case "call":
		// A call's Answer must reach the call that is ringing, so this one
		// listens rather than giving the button a deep link.
		l := kit.notify_listen("call")
		defer kit.notify_listen_close(&l)
		r := kit.notify({
			key = "call:7f3a",
			app = "call",
			class = .Person,
			urgency = .Critical,
			category = "call.incoming",
			title = "Ines Roux",
			body = "Incoming call · Northwind design review",
			actions = {{key = "answer", label = "Answer"}, {key = "decline", label = "Decline"}},
		})
		fmt.printfln("call: ok=%v id=%d delivery=%s why=%q", r.ok, r.id, r.delivery, r.why)
		if !r.ok || r.delivery != "toast" {
			return
		}
		for _ in 0 ..< 300 {
			if ev, got := kit.notify_next_action(&l); got {
				fmt.printfln("call: %s pressed (%s, %s)", ev.action, ev.key, ev.identity)
				return
			}
			time.sleep(100 * time.Millisecond)
		}
		fmt.println("call: nobody answered")

	case "withdraw":
		fmt.printfln("withdraw: %v", kit.notify_withdraw("call:7f3a"))
	}
}
