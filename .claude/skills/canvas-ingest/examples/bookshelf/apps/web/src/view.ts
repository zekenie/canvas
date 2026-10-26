/** The few pieces every page is drawn with: a heading, a list, a button. */

export function heading(text: string): HTMLElement {
  return Object.assign(document.createElement("h1"), { textContent: text });
}

export function list(items: string[]): HTMLElement {
  const ul = document.createElement("ul");
  ul.append(...items.map((item) => Object.assign(document.createElement("li"), { textContent: item })));
  return ul;
}

export function button(label: string, onClick: () => void): HTMLElement {
  return Object.assign(document.createElement("button"), { textContent: label, onclick: onClick });
}

/** A page: its heading over what it shows. */
export function page(title: string, ...parts: HTMLElement[]): HTMLElement {
  const main = document.createElement("main");
  main.append(heading(title), ...parts);
  return main;
}
