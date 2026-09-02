import * as fs from "node:fs/promises";
import * as os from "node:os";
import * as path from "node:path";

const registryRoot =
  process.env.OMP_MINI_SYNC_DIR || path.join(os.homedir(), ".omp", "mini-chat", "live");

export default function ompMiniAutoSync(pi) {
  let recordPath;
  let timer;
  let activeContext;
  let operation = Promise.resolve();
  let lastError;

  const serial = (work) => {
    operation = operation.then(work, work);
    return operation;
  };

  const removeRecord = async () => {
    const target = recordPath;
    recordPath = undefined;
    if (!target) return;
    try {
      await fs.unlink(target);
    } catch (error) {
      if (error?.code !== "ENOENT") throw error;
    }
  };

  const writeRecord = async (ctx, info) => {
    const sessionId = ctx.sessionManager.getSessionId();
    if (!sessionId) return;
    await fs.mkdir(registryRoot, { recursive: true, mode: 0o700 });
    await fs.chmod(registryRoot, 0o700);

    const nextPath = path.join(registryRoot, `${sessionId}.${process.pid}.json`);
    const temporaryPath = `${nextPath}.${Date.now()}.tmp`;
    const payload = JSON.stringify({
      version: 1,
      sessionId,
      sessionFile: ctx.sessionManager.getSessionFile(),
      title: ctx.sessionManager.getSessionName(),
      cwd: ctx.cwd,
      link: info.link,
      viewLink: info.viewLink,
      pid: process.pid,
      updatedAt: new Date().toISOString(),
    });
    await fs.writeFile(temporaryPath, payload, { encoding: "utf8", mode: 0o600 });
    await fs.chmod(temporaryPath, 0o600);
    await fs.rename(temporaryPath, nextPath);
    if (recordPath && recordPath !== nextPath) await removeRecord();
    recordPath = nextPath;
  };

  const hostCurrentSession = async (ctx) => {
    if (ctx.mode !== "tui" || !ctx.collab) return;
    try {
      const info = ctx.collab.info() || (await ctx.collab.start());
      await writeRecord(ctx, info);
      lastError = undefined;
    } catch (error) {
      await removeRecord();
      const message = error instanceof Error ? error.message : String(error);
      if (message !== lastError) {
        ctx.ui.notify(`Mini Chat automatic sync unavailable: ${message}`, "warning");
        lastError = message;
      }
    }
  };

  const stopHosting = async (ctx, reason) => {
    await removeRecord();
    await ctx.collab?.stop(reason);
  };

  pi.on("session_start", async (_event, ctx) => {
    if (ctx.mode !== "tui" || !ctx.collab) return;
    activeContext = ctx;
    await serial(() => hostCurrentSession(ctx));
    timer = ctx.setInterval(() => {
      if (activeContext) return serial(() => hostCurrentSession(activeContext));
    }, 2_000);
  });

  pi.on("session_before_switch", async (_event, ctx) => {
    await serial(() => stopHosting(ctx, "session switching"));
  });

  pi.on("session_switch", async (_event, ctx) => {
    activeContext = ctx;
    await serial(() => hostCurrentSession(ctx));
  });

  pi.on("session_shutdown", async (_event, ctx) => {
    activeContext = undefined;
    if (timer) ctx.clearTimer(timer);
    await serial(() => stopHosting(ctx, "OMP closed"));
  });
}
