/**
 * dsh-lan-access — DeepSeek Harness LAN-access bundle plugin.
 * Binds the dsh web server to 0.0.0.0 and injects a secure-context shim
 * (crypto.randomUUID) for phone browsers on the trusted home LAN.
 */

/** Stable Cordis plugin name. */
export const name: string;

/** Services required before this row mounts. */
export const inject: string[];

/**
 * Mount the row: register the index tap and announce the LAN URL once the
 * web server settles.
 */
export function apply(ctx: import("@deepseek-ai/cordis").Context): void;
