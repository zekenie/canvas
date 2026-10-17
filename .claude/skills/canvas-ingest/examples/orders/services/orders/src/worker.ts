/** The orders worker: runs the checkout and refund workflows, and their activities, on the task queue "orders". */

import { Worker } from "@temporalio/worker";
import * as activities from "./activities";

/** Starts the worker and runs it until it is stopped. */
export async function run(): Promise<void> {
  const worker = await Worker.create({
    workflowsPath: require.resolve("./workflows"),
    activities,
    taskQueue: "orders",
  });
  await worker.run();
}

run().catch((error) => {
  console.error(error);
  process.exit(1);
});
