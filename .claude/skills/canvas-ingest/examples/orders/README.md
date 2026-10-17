# The orders example

A small TypeScript monorepo, set up for `ingest` as a team sets theirs up: its settings, `.canvas/ingest.json`, and its lens, `.canvas/lens.py`. Read the lens as the model for a lens of your own.

- `packages/shared`: money and ids.
- `packages/db`: the Postgres client, and the functions that read and write the tables, each with its SQL.
- `services/orders`: Temporal. Two workflows in `src/workflows/`, the activities they run through `proxyActivities` in `src/activities/`, and the worker.
- `services/billing`: two Lambdas, declared in `serverless.yml`, their handlers in `src/handlers/`.
- `db/migrations/`: the tables, `customers`, `orders`, `payments` and `refunds`, and a column added to `orders` later.

The lens draws the root with the services as cards, a frame of the tables (Database) and a frame of the types. Each service's board has a frame of its workflows, then its activities, then its Lambdas. The types are Workflow, Activity, Lambda and Table, and the relationship types `runs` (a workflow runs an activity), `reads` and `writes` (an activity or a Lambda reads or writes a table). Each decision is a named rule at the top of the lens, with its reason.

`scan.json` is the scan, written by hand for this example in the scan format (`reference/scan.md`): what scip-typescript and `scanners/scip_read.py` would make of the code. On a real repository `ingest` makes the scan itself, with the `scip` command in the settings. The example has no `package-lock.json`, so its `prepare` (`npm ci`) would fail as it is; a real repository has one.

To draw it, copy it into a git repository of its own and commit it, then draw it from its scan, with an empty board in front (`$SKILL` is the skill's folder):

```bash
cp -R "$SKILL/examples/orders" ~/shop && cd ~/shop && rm scan.json
git init -q && git add -A && git commit -qm "the orders example"
"$SKILL/ingest" --scan "$SKILL/examples/orders/scan.json"
```

## What it answers

Each block is a `canvas query`, and its first line says what it answers on the drawn board.

The workflows:

```query
/* matches: "checkoutWorkflow", "refundWorkflow" */
:is-a("Workflow")
```

Who writes the orders table (activities only; no Lambda writes it):

```query
/* matches: "createOrder", "markPaid", "markRefunded" */
:start-of(arrow:is-a("writes"):ends-at("orders"))
```

Which workflows write orders, through the activities they run:

```query
/* matches: "checkoutWorkflow", "refundWorkflow" */
:start-of(arrow:is-a("runs"):ends-at(:start-of(arrow:is-a("writes"):ends-at("orders"))))
```

Which workflows write refunds:

```query
/* matches: "refundWorkflow" */
:start-of(arrow:is-a("runs"):ends-at(:start-of(arrow:is-a("writes"):ends-at("refunds"))))
```

Who writes payments: an activity, and a Lambda:

```query
/* matches: "chargeCard", "paymentWebhook" */
:start-of(arrow:is-a("writes"):ends-at("payments"))
```

What the checkout runs:

```query
/* matches: "createOrder", "chargeCard", "markPaid" */
:end-of(arrow:is-a("runs"):starts-at("checkoutWorkflow"))
```

The activity no workflow runs, since `run by` is Needed (the rule "every-activity-is-run"):

```query
/* matches: "sendReceipt" */
:incomplete
```

How many arrows say who reads a table:

```query
/* count: 8 */
arrow:is-a("reads")
```

## What the lens does not read

The lens finds things by this repository's conventions. What it does not read it passes over, and says so as a `lens:` warning where it can tell; where it cannot, the board is quietly missing the arrow. A lens for another repository starts from these and changes the ones that don't hold.

- **A service is a module under `services/`.** A module elsewhere with a `workflows/` or `activities/` folder is warned and not drawn.
- **Workflows and activities are exported functions** of the files in `workflows/` and `activities/` folders. An exported helper in `activities/` that no workflow runs is an activity all the same, and is `:incomplete`; the lens assumes such a file holds only activities. A class-based worker, or activities registered some other way, are not read.
- **A workflow runs what it calls through `proxyActivities`**, read as `const { a, b } = proxyActivities(...)` or `const acts = proxyActivities(...)` and `acts.a()`, the SDK imported by name or as a namespace (`wf.proxyActivities`). A workflow file that mentions `proxyActivities` and runs no activity (a helper that builds the proxy) is warned. An activity passed as a value (`execute: getWeather`) or called from a private helper or a class's method is not a call the lens reads, and says nothing.
- **Lambdas are the `functions` of a `serverless.yml`**, written in the file itself and read by lenskit's YAML reader. `functions: ${file(./functions.yml)}`, a file that is no mapping, anchors and tags are warned and left out; CDK and SAM are not read.
- **Reads and writes follow exported functions.** The tables a function touches are those named by SQL in its own strings (a string counts only with a `SELECT`, `INSERT`, `UPDATE` or `DELETE` in it) and in the exported functions it calls, in its file or in a file the scan says it uses. A private helper that holds the SQL, a query builder, an ORM, or a class-based data layer gives no reads or writes, and says nothing. A table no migration makes is warned.
- **Tables are what `db/migrations/*.sql` leave**, read by lenskit's SQL reader ([its limits](../../reference/lens.md#reading-sql-migrations)); a schema kept anywhere else is not read.
- A doc is the first sentence of the JSDoc over a declaration.
