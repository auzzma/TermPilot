import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";
import { GPLLicenseDialog } from "./GPLLicenseDialog";

describe("GPL license dialog", () => {
  it("renders the complete offline license with a named modal and close controls", () => {
    const markup = renderToStaticMarkup(<GPLLicenseDialog onClose={() => undefined} />);
    expect(markup).toContain("<dialog");
    expect(markup).toContain("aria-labelledby=");
    expect(markup).toContain("GNU General Public License v3.0");
    expect(markup).toContain("Version 3, 29 June 2007");
    expect(markup).toContain("END OF TERMS AND CONDITIONS");
    expect(markup).toContain("https://www.gnu.org/licenses/why-not-lgpl.html");
    expect(markup).toContain("<footer><button");
  });
});
