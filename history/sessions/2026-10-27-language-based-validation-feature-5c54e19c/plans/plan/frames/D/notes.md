# D · Agents (component 10): F12, F13

**F12.** An agent dry-runs Listing's schema with a third rule ("The description names no price."), then reads `:warned`. The dry run is real output, trimmed with `…`. The second answer is built: the real `:is-a("Listing")` row of the first of the facts' nine `ringed` listings, plus `problems` from `quotes` (one row, then `…`; 49 rows hold no second). The tinted lines are what's new.

**F13.** `canvas decide` over the 12 listings: a real run (jev-1.14.0, 12 calls, `decide-run.jsonl`, the prototype's code), rows sorted by yes.

**Where real data changed the brief**
- Listing's own schema holds no fields (they're Car's): only its two rules were kept.
- A dry run stores nothing, so `:warned` shows what the stored rules flag (nine, two false alarms), not the third rule.
- Today `:warned` lists no `problems` and doesn't wait (correction): both tagged new.
- Output is the JSON an agent's shell gets; a terminal gets a text table. F13's rows print one a line (the printer gives each five: 60). Its envelope mirrors `canvas query`'s; `question` and `model` are mine, and its instructions start "Judging from the state," (the prototype's lead-in).

**Not in the list**
- `registrar.drawChecks` takes one contribution (Validation's): a LanguageRules one would be refused as it stands.
- RuleContext's module (LanguageRules assumed); how Validation's words ask to wait (unnamed); `decide`'s output members.

**Left out:** a Keys line (no stops); what the model was shown (`decide` prints none). Output lines are verbatim or `…` (`src/cliprint.py` matches four real outputs byte for byte).
