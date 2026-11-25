import type { InstalledAddon } from "../../api/addons";

export type PinnedAddon = Pick<InstalledAddon, "id" | "name" | "entryPath" | "enabled">;

export function loadPinnedAddons(): PinnedAddon[] {
  try {
    const raw = window.localStorage.getItem("dunePinnedAddons");
    const parsed = JSON.parse(raw || "[]");
    if (!Array.isArray(parsed)) return [];
    return parsed
      .map((item) => ({
        id: typeof item?.id === "string" ? item.id : "",
        name: typeof item?.name === "string" ? item.name : "",
        entryPath: typeof item?.entryPath === "string" ? item.entryPath : "",
        enabled: item?.enabled === true
      }))
      .filter((item) => item.id && item.name && item.entryPath && item.enabled);
  } catch {
    return [];
  }
}

export function savePinnedAddons(addons: PinnedAddon[]) {
  try {
    window.localStorage.setItem("dunePinnedAddons", JSON.stringify(addons));
  } catch {
    // Browser storage can be unavailable in hardened modes.
  }
}
