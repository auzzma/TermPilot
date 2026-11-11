import { useEffect, useId, useRef, type ReactNode } from "react";
import { useTranslation } from "../i18n";

export function BatchDialog({title, onClose, className = "", children}: {
  title: string; onClose: () => void; className?: string; children: ReactNode;
}) {
  const t = useTranslation(), titleId = useId();
  const dialog = useRef<HTMLDialogElement>(null);
  useEffect(() => {
    const element = dialog.current!;
    const previous = document.activeElement instanceof HTMLElement ? document.activeElement : null;
    element.showModal();
    return () => { element.close(); previous?.focus(); };
  }, []);
  return <dialog ref={dialog} className={`batch-dialog ${className}`} aria-labelledby={titleId}
    onCancel={e => {e.preventDefault(); e.stopPropagation(); onClose();}}>
    <header><h2 id={titleId}>{title}</h2><button autoFocus aria-label={t("Close")} onClick={onClose}>×</button></header>
    <div className="batch-dialog-body">{children}</div>
    <footer><button onClick={onClose}>{t("Done")}</button></footer>
  </dialog>;
}
