/** Money as whole cents and a currency, so a total never picks up a float's error. */

export interface Money {
  cents: number;
  currency: string;
}

/** An amount in cents, in US dollars unless it says otherwise. */
export function money(cents: number, currency = "USD"): Money {
  if (!Number.isInteger(cents)) throw new Error(`money is whole cents, not ${cents}`);
  return { cents, currency };
}

/** The sum of two amounts in one currency. */
export function add(a: Money, b: Money): Money {
  if (a.currency !== b.currency) throw new Error(`can't add ${a.currency} to ${b.currency}`);
  return { cents: a.cents + b.cents, currency: a.currency };
}
