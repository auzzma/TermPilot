import { Check, ChevronDown } from "lucide-react";
import {
  useEffect,
  useId,
  useRef,
  useState,
  type CSSProperties,
  type KeyboardEvent,
} from "react";
import { createPortal } from "react-dom";

export interface SelectOption {
  value: string;
  label: string;
  group?: string;
}

// Render the popup ourselves: WebView2's OS-drawn select popup does not
// consistently follow the app theme independently of Windows appearance.
export function ThemedSelect({
  label,
  value,
  options,
  onChange,
  placeholder = "请选择",
  className = "",
  disabled = false,
}: {
  label: string;
  value: string;
  options: SelectOption[];
  onChange: (value: string) => void;
  placeholder?: string;
  className?: string;
  disabled?: boolean;
}) {
  const id = useId();
  const trigger = useRef<HTMLButtonElement>(null);
  const popup = useRef<HTMLDivElement>(null);
  const [open, setOpen] = useState(false);
  const [active, setActive] = useState(0);
  const [position, setPosition] = useState<CSSProperties>({});
  const search = useRef({ text: "", time: 0 });
  const selected = options.findIndex((option) => option.value === value);

  function show(last = false) {
    const rect = trigger.current!.getBoundingClientRect();
    const width = Math.min(Math.max(rect.width, 220), window.innerWidth - 16);
    const below = window.innerHeight - rect.bottom;
    const above = below < 240 && rect.top > below;
    setPosition({
      position: "fixed",
      width,
      left: Math.max(8, Math.min(rect.left, window.innerWidth - width - 8)),
      ...(above
        ? { bottom: window.innerHeight - rect.top + 4 }
        : { top: rect.bottom + 4 }),
      maxHeight: Math.min(320, Math.max(80, (above ? rect.top : below) - 12)),
    });
    setActive(selected >= 0 ? selected : last ? options.length - 1 : 0);
    setOpen(true);
  }
  function choose(index: number) {
    const option = options[index];
    if (!option) return;
    setOpen(false);
    onChange(option.value);
    trigger.current?.focus();
  }
  useEffect(() => {
    if (!open) return;
    const outside = (event: PointerEvent) => {
      if (
        !trigger.current?.contains(event.target as Node) &&
        !popup.current?.contains(event.target as Node)
      )
        setOpen(false);
    };
    const close = () => setOpen(false);
    const scrolled = (event: Event) => {
      if (!popup.current?.contains(event.target as Node)) close();
    };
    document.addEventListener("pointerdown", outside);
    window.addEventListener("resize", close);
    document.addEventListener("scroll", scrolled, true);
    return () => {
      document.removeEventListener("pointerdown", outside);
      window.removeEventListener("resize", close);
      document.removeEventListener("scroll", scrolled, true);
    };
  }, [open]);
  useEffect(() => {
    if (open)
      popup.current
        ?.querySelector(`[data-option-index="${active}"]`)
        ?.scrollIntoView({ block: "nearest" });
  }, [open, active]);

  function keyDown(event: KeyboardEvent<HTMLButtonElement>) {
    if (event.key === "Tab") {
      setOpen(false);
      return;
    }
    if (event.key === "Escape") {
      if (open) {
        event.preventDefault();
        event.stopPropagation();
        setOpen(false);
      }
      return;
    }
    if (
      ["Enter", " ", "ArrowDown", "ArrowUp", "Home", "End"].includes(event.key)
    ) {
      event.preventDefault();
      if (!open) {
        show(event.key === "ArrowUp" || event.key === "End");
        return;
      }
      if (event.key === "Enter" || event.key === " ") {
        choose(active);
        return;
      }
      setActive((index) =>
        event.key === "Home"
          ? 0
          : event.key === "End"
            ? options.length - 1
            : Math.max(
                0,
                Math.min(
                  options.length - 1,
                  index + (event.key === "ArrowDown" ? 1 : -1),
                ),
              ),
      );
    } else if (
      event.key.length === 1 &&
      !event.ctrlKey &&
      !event.metaKey &&
      !event.altKey
    ) {
      const now = Date.now();
      search.current = {
        text:
          (now - search.current.time < 700 ? search.current.text : "") +
          event.key.toLocaleLowerCase(),
        time: now,
      };
      const index = options.findIndex((o) =>
        o.label.toLocaleLowerCase().startsWith(search.current.text),
      );
      if (index >= 0) {
        event.preventDefault();
        if (!open) show();
        setActive(index);
      }
    }
  }

  return (
    <div className={`themed-select ${className}`}>
      <button
        ref={trigger}
        disabled={disabled}
        type="button"
        className="themed-select-trigger"
        role="combobox"
        aria-label={label}
        aria-expanded={open}
        aria-haspopup="listbox"
        aria-controls={open ? id : undefined}
        aria-activedescendant={
          open && options[active] ? `${id}-${active}` : undefined
        }
        onClick={() => (open ? setOpen(false) : show())}
        onKeyDown={keyDown}
        onBlur={(event) => {
          if (!popup.current?.contains(event.relatedTarget as Node))
            setOpen(false);
        }}
      >
        <span>{options[selected]?.label ?? placeholder}</span>
        <ChevronDown size={14} aria-hidden="true" />
      </button>
      {open &&
        createPortal(
          <div
            ref={popup}
            id={id}
            role="listbox"
            aria-label={label}
            className="themed-select-menu"
            style={position}
          >
            {options.length === 0 && (
              <div className="themed-select-empty">暂无可用选项</div>
            )}
            {options.map((option, index) => (
              <div key={option.value} role="presentation">
                {option.group && option.group !== options[index - 1]?.group && (
                  <div className="themed-select-group" role="presentation">
                    {option.group}
                  </div>
                )}
                <button
                  type="button"
                  role="option"
                  id={`${id}-${index}`}
                  aria-selected={option.value === value}
                  tabIndex={-1}
                  data-option-index={index}
                  className={active === index ? "is-active" : ""}
                  onPointerMove={() => setActive(index)}
                  onPointerDown={(event) => event.preventDefault()}
                  onClick={() => choose(index)}
                >
                  <span>{option.label}</span>
                  {option.value === value && (
                    <Check size={14} aria-hidden="true" />
                  )}
                </button>
              </div>
            ))}
          </div>,
          document.body,
        )}
    </div>
  );
}
