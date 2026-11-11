import { createElement, ReactNode } from "react";
import type { AIValue } from "../ai";
export function Markdown({ blocks }: { blocks: AIValue[] }) {
  return (
    <>
      {blocks.map((b, i) => (
        <Block key={i} block={b} />
      ))}
    </>
  );
}
function Block({ block: b }: { block: AIValue }): ReactNode {
  const children = <Markdown blocks={b.children ?? []} />;
  switch (b.kind) {
    case "text":
      return b.text;
    case "code":
      return <code>{b.text}</code>;
    case "link":
      return (
        <a
          href={/^https?:|^mailto:/.test(b.url ?? "") ? b.url : undefined}
          target="_blank"
          rel="noreferrer"
        >
          {children}
        </a>
      );
    case "image":
      return <span>{children}</span>;
    case "rule":
      return <hr />;
    case "table":
      return (
        <div className="ai-table-scroll">
          <table>
            <tbody>{children}</tbody>
          </table>
        </div>
      );
    case "tableHead":
    case "tableRow":
      return <tr>{children}</tr>;
    case "tableCell":
      return <td>{children}</td>;
    case "list":
      return b.start != null ? (
        <ol start={b.start}>{children}</ol>
      ) : (
        <ul>{children}</ul>
      );
    case "heading":
      return createElement(
        `h${Math.min(6, Math.max(1, b.level))}`,
        null,
        children,
      );
    case "codeBlock":
      return (
        <div className="ai-code">
          <button onClick={() => navigator.clipboard.writeText(text(b))}>
            复制
          </button>
          <pre>
            <code>{children}</code>
          </pre>
        </div>
      );
    default: {
      const tags: Record<string, string> = {
        paragraph: "p",
        quote: "blockquote",
        item: "li",
        strong: "strong",
        emphasis: "em",
        strike: "s",
      };
      return createElement(tags[b.kind] ?? "span", null, children);
    }
  }
}
function text(b: AIValue): string {
  return (b.text ?? "") + (b.children ?? []).map(text).join("");
}
