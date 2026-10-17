/** The card provider's webhook: a payment settled. */

import type { APIGatewayProxyEvent, APIGatewayProxyResult } from "aws-lambda";
import { settlePayment } from "@shop/db";

/** Marks the payment the provider names settled. */
export async function handler(event: APIGatewayProxyEvent): Promise<APIGatewayProxyResult> {
  const { ref, type } = JSON.parse(event.body ?? "{}") as { ref?: string; type?: string };
  if (type !== "payment.settled" || !ref) return { statusCode: 204, body: "" };
  await settlePayment(ref);
  return { statusCode: 200, body: "settled" };
}
