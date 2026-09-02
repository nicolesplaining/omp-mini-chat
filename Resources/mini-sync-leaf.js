export default function miniSyncLeafExtension(pi) {
  pi.registerCommand("mini-sync-leaf", {
    description: "Move the embedded client to an existing session-tree leaf",
    handler: async (args, ctx) => {
      const entryId = args.trim();
      if (!entryId) throw new Error("Missing session entry ID");
      await ctx.navigateTree(entryId, { summarize: false });
    },
  });
}
