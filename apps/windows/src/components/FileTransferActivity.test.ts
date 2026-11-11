import { describe, expect, it, vi } from "vitest";
import { clearFinishedTransfers, controlFileTransfer, registerTransferControl, useTransferStore, type TransferRecord } from "./SftpPanel";
import { transferSpeed } from "./FileTransferActivity";

const record = (id: string, state: TransferRecord["state"] = "running"): TransferRecord => ({
  id, transferKey:id, name:id, direction:"upload", transferred:100, total:1000,
  bytesPerSecond:1024, sampledAt:1000, sampledBytes:100, state,
});
describe("global file transfer controls", () => {
  it("targets only the chosen task and keeps active tasks when clearing history", async () => {
    const upload = vi.fn(async () => {}), download = vi.fn(async () => {});
    registerTransferControl("sftp", upload); registerTransferControl("rdp", download);
    useTransferStore.setState({transfers:[record("sftp"),record("rdp","paused"),record("done","completed")]});
    await controlFileTransfer("sftp","pause");
    await controlFileTransfer("rdp","resume");
    expect(upload).toHaveBeenCalledExactlyOnceWith("pause");
    expect(download).toHaveBeenCalledExactlyOnceWith("resume");
    clearFinishedTransfers();
    expect(useTransferStore.getState().transfers.map(t => t.id)).toEqual(["sftp","rdp"]);
    registerTransferControl("sftp"); registerTransferControl("rdp");
    useTransferStore.setState({transfers:[]});
  });
  it("does not show stale speed for paused, finished or idle transfers", () => {
    expect(transferSpeed(record("a"),1500)).toBe(1024);
    expect(transferSpeed(record("a"),4000)).toBe(0);
    expect(transferSpeed(record("a","paused"),1500)).toBe(0);
    expect(transferSpeed(record("a","completed"),1500)).toBe(0);
  });
});
