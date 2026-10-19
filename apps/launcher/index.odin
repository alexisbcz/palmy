package main

// The application index, the matcher, the launch history and the pins live
// in kit:appindex, shared with the start menu the window manager draws, so
// the two front ends cannot disagree about what is installed, how a query
// ranks, or what is pinned. These names keep the launcher's code reading as
// it always did.

import ai "kit:appindex"

Entry :: ai.Entry
Category :: ai.Category
Ranked :: ai.Ranked
Hit :: ai.Hit
CAT_LABEL := ai.CAT_LABEL

index_apps :: ai.index_apps
parse_desktop :: ai.parse_desktop
load_usage :: ai.load_usage
clear_usage :: ai.clear_usage
rank_entry :: ai.rank_entry
split_exec :: ai.split_exec
hit_at :: ai.hit_at
hit_any :: ai.hit_any
entry_icon :: ai.icon_for
