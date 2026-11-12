import licenseText from "../../../../LICENSE?raw";
import { BatchDialog } from "./BatchDialog";

export const gplLicenseTitle = "GNU General Public License v3.0";

export function GPLLicenseDialog({ onClose }: { onClose: () => void }) {
  return (
    <BatchDialog title={gplLicenseTitle} onClose={onClose} className="gpl-license-dialog">
      <pre data-testid="gpl-license-text">{licenseText}</pre>
    </BatchDialog>
  );
}
