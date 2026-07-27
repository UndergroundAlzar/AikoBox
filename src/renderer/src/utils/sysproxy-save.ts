type PatchSysProxyConfig = (value: Partial<IAppConfig>) => Promise<void>
type ApplySysProxy = (enable: boolean) => Promise<unknown>

export async function saveSysProxySettings(
  sysProxy: IAppConfig['sysProxy'],
  patchAppConfig: PatchSysProxyConfig,
  applySysProxy: ApplySysProxy
): Promise<void> {
  await patchAppConfig({ sysProxy })
  await applySysProxy(sysProxy.enable)
}
