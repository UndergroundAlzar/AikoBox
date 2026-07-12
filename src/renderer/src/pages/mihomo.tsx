import {
  Button,
  Divider,
  Input,
  Select,
  SelectItem,
  Switch,
  Tooltip,
  Modal,
  ModalContent,
  ModalHeader,
  ModalBody,
  ModalFooter,
  Chip
} from '@heroui/react'
import BasePage from '@renderer/components/base/base-page'
import { showError } from '@renderer/utils/error-display'
import SettingCard from '@renderer/components/base/base-setting-card'
import SettingItem from '@renderer/components/base/base-setting-item'
import { isValidListenAddress, getError, isValid } from '@renderer/utils/validate'
import { useAppConfig } from '@renderer/hooks/use-app-config'
import { useControledMihomoConfig } from '@renderer/hooks/use-controled-mihomo-config'
import { platform } from '@renderer/utils/init'
import { FaNetworkWired } from 'react-icons/fa'
import { IoMdRefresh, IoMdShuffle, IoMdEye, IoMdEyeOff } from 'react-icons/io'
import useSWR from 'swr'
import {
  checkCoreUpdate,
  installCoreUpdate,
  mihomoVersion,
  mihomoHotReloadConfig,
  rollbackCoreUpdate,
  restartCore,
  startSubStoreBackendServer
} from '@renderer/utils/ipc'
import React, { useState, useEffect, useRef } from 'react'
import { toast } from '@renderer/components/base/toast'
import InterfaceModal from '@renderer/components/mihomo/interface-modal'
import { MdDeleteForever, MdEdit, MdDelete, MdOpenInNew } from 'react-icons/md'
import { useTranslation } from 'react-i18next'
import {
  DEFAULT_MIHOMO_LAN_ALLOWED_IPS,
  DEFAULT_MIHOMO_PORTS,
  DEFAULT_MIHOMO_SKIP_AUTH_PREFIXES
} from '../../../shared/appConfig'

interface WebUIPanel {
  id: string
  name: string
  url: string
  isDefault?: boolean
}

const defaultWebUIPanels: WebUIPanel[] = [
  {
    id: 'metacubexd',
    name: 'MetaCubeXD',
    url: 'https://metacubex.github.io/metacubexd/#/setup?http=true&hostname=%host&port=%port&secret=%secret',
    isDefault: true
  },
  {
    id: 'yacd',
    name: 'YACD',
    url: 'https://yacd.metacubex.one/?hostname=%host&port=%port&secret=%secret',
    isDefault: true
  },
  {
    id: 'zashboard',
    name: 'Zashboard',
    url: 'https://board.zash.run.place/#/setup?http=true&hostname=%host&port=%port&secret=%secret',
    isDefault: true
  }
]

const Mihomo: React.FC = () => {
  const { t } = useTranslation()
  const { appConfig, patchAppConfig } = useAppConfig()
  const {
    maxLogDays = 7,
    maxLogFileSize = 10,
    showMixedPort,
    enableMixedPort = true,
    showSocksPort,
    enableSocksPort = true,
    showHttpPort,
    enableHttpPort = true,
    showRedirPort,
    enableRedirPort = false,
    showTproxyPort,
    enableTproxyPort = false
  } = appConfig || {}
  const { controledMihomoConfig, patchControledMihomoConfig } = useControledMihomoConfig()
  const { data: coreVersion, mutate: mutateCoreVersion } = useSWR('mihomoVersion', mihomoVersion)
  const [coreUpdateInfo, setCoreUpdateInfo] = useState<ICoreReleaseInfo | null>(null)
  const [checkingCoreUpdate, setCheckingCoreUpdate] = useState(false)
  const [runningCoreUpdate, setRunningCoreUpdate] = useState(false)
  const [coreUpdateAction, setCoreUpdateAction] = useState<'install' | 'rollback' | null>(null)

  const {
    ipv6,
    'external-controller': externalController = '',
    secret = '',
    authentication = [],
    'skip-auth-prefixes': skipAuthPrefixes = DEFAULT_MIHOMO_SKIP_AUTH_PREFIXES,
    'log-level': logLevel = 'info',
    'allow-lan': allowLan,
    'lan-allowed-ips': lanAllowedIps = DEFAULT_MIHOMO_LAN_ALLOWED_IPS,
    'lan-disallowed-ips': lanDisallowedIps = [],
    'mixed-port': mixedPort = DEFAULT_MIHOMO_PORTS.mixed,
    'socks-port': socksPort = DEFAULT_MIHOMO_PORTS.socks,
    port: httpPort = DEFAULT_MIHOMO_PORTS.http,
    'redir-port': redirPort = DEFAULT_MIHOMO_PORTS.redir,
    'tproxy-port': tproxyPort = DEFAULT_MIHOMO_PORTS.tproxy,
    profile = {}
  } = controledMihomoConfig || {}
  const { 'store-fake-ip': storeFakeIp } = profile

  const [isManualPortChange, setIsManualPortChange] = useState(false)
  const [mixedPortInput, setMixedPortInput] = useState(showMixedPort ?? mixedPort)
  const [socksPortInput, setSocksPortInput] = useState(showSocksPort ?? socksPort)
  const [httpPortInput, setHttpPortInput] = useState(showHttpPort ?? httpPort)
  const [redirPortInput, setRedirPortInput] = useState(showRedirPort ?? redirPort)
  const [tproxyPortInput, setTproxyPortInput] = useState(showTproxyPort ?? tproxyPort)
  const [externalControllerInput, setExternalControllerInput] = useState(externalController)
  const [externalControllerError, setExternalControllerError] = useState<string | null>(() => {
    const result = isValidListenAddress(externalController)
    return isValid(result) ? null : (getError(result) ?? '格式错误')
  })
  const [secretInput, setSecretInput] = useState(secret)
  const [isSecretVisible, setIsSecretVisible] = useState(false)
  const [lanAllowedIpsInput, setLanAllowedIpsInput] = useState(lanAllowedIps)
  const [lanDisallowedIpsInput, setLanDisallowedIpsInput] = useState(lanDisallowedIps)
  const [authenticationInput, setAuthenticationInput] = useState(authentication)
  const [skipAuthPrefixesInput, setSkipAuthPrefixesInput] = useState(skipAuthPrefixes)
  const [lanOpen, setLanOpen] = useState(false)

  // WebUI 管理状态
  const [isWebUIModalOpen, setIsWebUIModalOpen] = useState(false)
  const [allPanels, setAllPanels] = useState<WebUIPanel[]>([])
  const [editingPanel, setEditingPanel] = useState<WebUIPanel | null>(null)
  const [newPanelName, setNewPanelName] = useState('')
  const [newPanelUrl, setNewPanelUrl] = useState('')

  const urlInputRef = useRef<HTMLInputElement>(null)

  // 解析主机和端口
  const parseController = () => {
    if (externalController) {
      const [host, port] = externalController.split(':')
      return { host: host.replace('0.0.0.0', '127.0.0.1'), port }
    }
    return { host: '127.0.0.1', port: '9090' }
  }

  const { host, port } = parseController()

  // 生成随机端口 (范围 1024-65535)
  const generateRandomPort = () => Math.floor(Math.random() * (65535 - 1024 + 1)) + 1024

  // 初始化面板列表
  useEffect(() => {
    const savedPanels = localStorage.getItem('webui-panels')
    if (savedPanels) {
      setAllPanels(JSON.parse(savedPanels))
    } else {
      setAllPanels(defaultWebUIPanels)
    }
  }, [])

  // 保存面板列表到 localStorage
  useEffect(() => {
    if (allPanels.length > 0) {
      localStorage.setItem('webui-panels', JSON.stringify(allPanels))
    }
  }, [allPanels])

  // 在 URL 输入框光标处插入或替换变量
  const insertVariableAtCursor = (variable: string) => {
    if (!urlInputRef.current) return

    const input = urlInputRef.current
    const start = input.selectionStart || 0
    const end = input.selectionEnd || 0
    const currentValue = newPanelUrl || ''

    // 如果有选中文本，则替换选中的文本
    const newValue = currentValue.substring(0, start) + variable + currentValue.substring(end)

    setNewPanelUrl(newValue)

    // 设置光标位置到插入变量之后
    setTimeout(() => {
      if (urlInputRef.current) {
        const newCursorPos = start + variable.length
        urlInputRef.current.setSelectionRange(newCursorPos, newCursorPos)
        urlInputRef.current.focus()
      }
    }, 0)
  }

  // 打开 WebUI 面板
  const openWebUI = (panel: WebUIPanel) => {
    const url = panel.url.replace('%host', host).replace('%port', port).replace('%secret', secret)
    window.open(url, '_blank')
  }

  // 添加新面板
  const addNewPanel = () => {
    if (newPanelName && newPanelUrl) {
      const newPanel: WebUIPanel = {
        id: Date.now().toString(),
        name: newPanelName,
        url: newPanelUrl
      }
      setAllPanels([...allPanels, newPanel])
      setNewPanelName('')
      setNewPanelUrl('')
      setEditingPanel(null)
    }
  }

  // 更新面板
  const updatePanel = () => {
    if (editingPanel && newPanelName && newPanelUrl) {
      const updatedPanels = allPanels.map((panel) =>
        panel.id === editingPanel.id ? { ...panel, name: newPanelName, url: newPanelUrl } : panel
      )
      setAllPanels(updatedPanels)
      setEditingPanel(null)
      setNewPanelName('')
      setNewPanelUrl('')
    }
  }

  // 删除面板
  const deletePanel = (id: string) => {
    setAllPanels(allPanels.filter((panel) => panel.id !== id))
  }

  // 开始编辑面板
  const startEditing = (panel: WebUIPanel) => {
    setEditingPanel(panel)
    setNewPanelName(panel.name)
    setNewPanelUrl(panel.url)
  }

  // 取消编辑
  const cancelEditing = () => {
    setEditingPanel(null)
    setNewPanelName('')
    setNewPanelUrl('')
  }

  // 恢复默认面板
  const restoreDefaultPanels = () => {
    setAllPanels(defaultWebUIPanels)
  }

  // 用于高亮显示 URL 中的变量
  const HighlightedUrl: React.FC<{ url: string }> = ({ url }) => {
    const parts = url.split(/(%host|%port|%secret)/g)

    return (
      <p className="text-sm text-default-500 break-all">
        {parts.map((part, index) => {
          if (part === '%host' || part === '%port' || part === '%secret') {
            return (
              <span key={index} className="bg-warning-200 text-warning-800 px-1 rounded">
                {part}
              </span>
            )
          }
          return part
        })}
      </p>
    )
  }

  // 可点击的变量标签组件
  const ClickableVariableTag: React.FC<{
    variable: string
    onClick: (variable: string) => void
  }> = ({ variable, onClick }) => {
    return (
      <span
        className="bg-warning-200 text-warning-800 px-1 rounded ml-1 cursor-pointer hover:bg-warning-300"
        onClick={() => onClick(variable)}
      >
        {variable}
      </span>
    )
  }

  const onChangeNeedRestart = async (patch: Partial<IMihomoConfig>): Promise<void> => {
    await patchControledMihomoConfig(patch)
    try {
      if (appConfig?.useHotReloadProfile) {
        await mihomoHotReloadConfig()
      } else {
        await restartCore()
      }
    } catch (e) {
      const errorMessage = e instanceof Error ? e.message : String(e)
      console.error('Apply config change failed:', errorMessage)
      await showError(errorMessage, t('mihomo.error.profileCheckFailed'))
    }
  }

  return (
    <>
      {lanOpen && <InterfaceModal onClose={() => setLanOpen(false)} />}
      <Modal
        isOpen={coreUpdateAction !== null}
        isDismissable={!runningCoreUpdate}
        hideCloseButton={runningCoreUpdate}
        onOpenChange={(open) => {
          if (!open && !runningCoreUpdate) setCoreUpdateAction(null)
        }}
      >
        <ModalContent>
          <ModalHeader>
            {coreUpdateAction === 'rollback'
              ? t('mihomo.coreUpdater.rollbackTitle')
              : t('mihomo.coreUpdater.availableTitle')}
          </ModalHeader>
          <ModalBody>
            {coreUpdateAction === 'rollback' ? (
              <p>{t('mihomo.coreUpdater.rollbackDescription')}</p>
            ) : (
              <>
                <p>
                  {t('mihomo.coreUpdater.availableDescription', {
                    current: coreUpdateInfo?.currentVersion,
                    latest: coreUpdateInfo?.latestVersion
                  })}
                </p>
                <p className="text-sm text-default-500">
                  {t('mihomo.coreUpdater.securityDescription')}
                </p>
              </>
            )}
          </ModalBody>
          <ModalFooter>
            <Button
              variant="light"
              isDisabled={runningCoreUpdate}
              onPress={() => setCoreUpdateAction(null)}
            >
              {t('common.cancel')}
            </Button>
            <Button
              color={coreUpdateAction === 'rollback' ? 'warning' : 'primary'}
              isLoading={runningCoreUpdate}
              onPress={async () => {
                if (!coreUpdateAction) return
                setRunningCoreUpdate(true)
                try {
                  const result =
                    coreUpdateAction === 'rollback'
                      ? await rollbackCoreUpdate()
                      : await installCoreUpdate(coreUpdateInfo?.latestVersion || '')
                  setCoreUpdateInfo((previous) =>
                    previous
                      ? {
                          ...previous,
                          currentVersion: result.version,
                          updateAvailable: previous.latestVersion !== result.version,
                          canRollback: result.canRollback
                        }
                      : previous
                  )
                  await mutateCoreVersion()
                  toast.success(
                    coreUpdateAction === 'rollback'
                      ? t('mihomo.coreUpdater.rollbackSuccess', { version: result.version })
                      : t('mihomo.coreUpdater.updateSuccess', { version: result.version })
                  )
                  setCoreUpdateAction(null)
                } catch (error) {
                  toast.error(error instanceof Error ? error.message : String(error))
                } finally {
                  setRunningCoreUpdate(false)
                }
              }}
            >
              {coreUpdateAction === 'rollback'
                ? t('mihomo.coreUpdater.rollbackButton')
                : t('mihomo.coreUpdater.installButton')}
            </Button>
          </ModalFooter>
        </ModalContent>
      </Modal>
      <BasePage title={t('mihomo.title')}>
        {/* 内核信息 */}
        <SettingCard>
          <SettingItem title={t('mihomo.coreVersion')}>
            <div className="flex items-center gap-2">
              <Chip size="sm" variant="flat" color="primary">
                sing-box
              </Chip>
              <span className="text-default-500">{coreVersion?.version ?? '-'}</span>
              <Button
                size="sm"
                variant="flat"
                color="primary"
                isLoading={checkingCoreUpdate}
                onPress={async () => {
                  setCheckingCoreUpdate(true)
                  try {
                    const info = await checkCoreUpdate()
                    setCoreUpdateInfo(info)
                    if (info.updateAvailable) {
                      setCoreUpdateAction('install')
                    } else {
                      toast.success(
                        t('mihomo.coreUpdater.upToDate', { version: info.currentVersion })
                      )
                    }
                  } catch (error) {
                    toast.error(error instanceof Error ? error.message : String(error))
                  } finally {
                    setCheckingCoreUpdate(false)
                  }
                }}
              >
                {t('mihomo.coreUpdater.checkButton')}
              </Button>
              {coreUpdateInfo?.canRollback && (
                <Button
                  size="sm"
                  variant="light"
                  color="warning"
                  onPress={() => setCoreUpdateAction('rollback')}
                >
                  {t('mihomo.coreUpdater.rollbackButton')}
                </Button>
              )}
            </div>
          </SettingItem>
        </SettingCard>

        {/* 常规内核设置 */}
        <SettingCard>
          <SettingItem title={t('mihomo.mixedPort')} divider>
            <div className="flex">
              {isManualPortChange && mixedPortInput !== mixedPort && (
                <Button
                  size="sm"
                  color="primary"
                  className="mr-2"
                  onPress={async () => {
                    await onChangeNeedRestart({ 'mixed-port': mixedPortInput })
                    await startSubStoreBackendServer()
                  }}
                >
                  {t('mihomo.confirm')}
                </Button>
              )}

              <Input
                size="sm"
                type="number"
                className="w-25"
                value={(showMixedPort ?? mixedPort ?? '').toString()}
                max={65535}
                min={0}
                onValueChange={(v) => {
                  const port = v === '' ? 0 : parseInt(v)
                  if (!isNaN(port) && port >= 0 && port <= 65535) {
                    setMixedPortInput(port)
                    patchAppConfig({ showMixedPort: port })
                    setIsManualPortChange(true)
                  }
                }}
              />
              <Button
                isIconOnly
                size="sm"
                variant="light"
                className="ml-2"
                onPress={() => {
                  const randomPort = generateRandomPort()
                  setMixedPortInput(randomPort)
                  patchAppConfig({ showMixedPort: randomPort })
                  setIsManualPortChange(true)
                }}
              >
                <IoMdShuffle className="text-lg" />
              </Button>
              <Switch
                size="sm"
                className="ml-2"
                isSelected={enableMixedPort}
                onValueChange={(value) => {
                  patchAppConfig({ enableMixedPort: value })
                  if (value) {
                    const port = appConfig?.showMixedPort
                    onChangeNeedRestart({ 'mixed-port': port })
                  } else {
                    onChangeNeedRestart({ 'mixed-port': 0 })
                  }
                }}
              />
            </div>
          </SettingItem>
          <SettingItem title={t('mihomo.socksPort')} divider>
            <div className="flex">
              {isManualPortChange && socksPortInput !== socksPort && (
                <Button
                  size="sm"
                  color="primary"
                  className="mr-2"
                  onPress={async () => {
                    await onChangeNeedRestart({ 'socks-port': socksPortInput })
                  }}
                >
                  {t('mihomo.confirm')}
                </Button>
              )}

              <Input
                size="sm"
                type="number"
                className="w-25"
                value={(showSocksPort ?? socksPort ?? '').toString()}
                max={65535}
                min={0}
                onValueChange={(v) => {
                  const port = v === '' ? 0 : parseInt(v)
                  if (!isNaN(port) && port >= 0 && port <= 65535) {
                    setSocksPortInput(port)
                    patchAppConfig({ showSocksPort: port })
                    setIsManualPortChange(true)
                  }
                }}
              />
              <Button
                isIconOnly
                size="sm"
                variant="light"
                className="ml-2"
                onPress={() => {
                  const randomPort = generateRandomPort()
                  setSocksPortInput(randomPort)
                  patchAppConfig({ showSocksPort: randomPort })
                  setIsManualPortChange(true)
                }}
              >
                <IoMdShuffle className="text-lg" />
              </Button>
              <Switch
                size="sm"
                className="ml-2"
                isSelected={enableSocksPort}
                onValueChange={(value) => {
                  patchAppConfig({ enableSocksPort: value })
                  if (value) {
                    const port = appConfig?.showSocksPort ?? socksPort
                    onChangeNeedRestart({ 'socks-port': port })
                  } else {
                    onChangeNeedRestart({ 'socks-port': 0 })
                  }
                }}
              />
            </div>
          </SettingItem>
          <SettingItem title={t('mihomo.httpPort')} divider>
            <div className="flex">
              {isManualPortChange && httpPortInput !== httpPort && (
                <Button
                  size="sm"
                  color="primary"
                  className="mr-2"
                  onPress={async () => {
                    await onChangeNeedRestart({ port: httpPortInput })
                  }}
                >
                  {t('mihomo.confirm')}
                </Button>
              )}

              <Input
                size="sm"
                type="number"
                className="w-25"
                value={(showHttpPort ?? httpPort ?? '').toString()}
                max={65535}
                min={0}
                onValueChange={(v) => {
                  const port = v === '' ? 0 : parseInt(v)
                  if (!isNaN(port) && port >= 0 && port <= 65535) {
                    setHttpPortInput(port)
                    patchAppConfig({ showHttpPort: port })
                    setIsManualPortChange(true)
                  }
                }}
              />
              <Button
                isIconOnly
                size="sm"
                variant="light"
                className="ml-2"
                onPress={() => {
                  const randomPort = generateRandomPort()
                  setHttpPortInput(randomPort)
                  patchAppConfig({ showHttpPort: randomPort })
                  setIsManualPortChange(true)
                }}
              >
                <IoMdShuffle className="text-lg" />
              </Button>
              <Switch
                size="sm"
                className="ml-2"
                isSelected={enableHttpPort}
                onValueChange={(value) => {
                  patchAppConfig({ enableHttpPort: value })
                  if (value) {
                    const port = appConfig?.showHttpPort ?? httpPort
                    onChangeNeedRestart({ port: port })
                  } else {
                    onChangeNeedRestart({ port: 0 })
                  }
                }}
              />
            </div>
          </SettingItem>
          {platform !== 'win32' && (
            <SettingItem title={t('mihomo.redirPort')} divider>
              <div className="flex">
                {isManualPortChange && redirPortInput !== redirPort && (
                  <Button
                    size="sm"
                    color="primary"
                    className="mr-2"
                    onPress={async () => {
                      await onChangeNeedRestart({ 'redir-port': redirPortInput })
                    }}
                  >
                    {t('mihomo.confirm')}
                  </Button>
                )}

                <Input
                  size="sm"
                  type="number"
                  className="w-25"
                  value={(showRedirPort ?? redirPort ?? '').toString()}
                  max={65535}
                  min={0}
                  onValueChange={(v) => {
                    const port = v === '' ? 0 : parseInt(v)
                    if (!isNaN(port) && port >= 0 && port <= 65535) {
                      setRedirPortInput(port)
                      patchAppConfig({ showRedirPort: port })
                      setIsManualPortChange(true)
                    }
                  }}
                />
                <Button
                  isIconOnly
                  size="sm"
                  variant="light"
                  className="ml-2"
                  onPress={() => {
                    const randomPort = generateRandomPort()
                    setRedirPortInput(randomPort)
                    patchAppConfig({ showRedirPort: randomPort })
                    setIsManualPortChange(true)
                  }}
                >
                  <IoMdShuffle className="text-lg" />
                </Button>
                <Switch
                  size="sm"
                  className="ml-2"
                  isSelected={enableRedirPort}
                  onValueChange={(value) => {
                    patchAppConfig({ enableRedirPort: value })
                    if (value) {
                      const port = appConfig?.showRedirPort ?? redirPort
                      onChangeNeedRestart({ 'redir-port': port })
                    } else {
                      onChangeNeedRestart({ 'redir-port': 0 })
                    }
                  }}
                />
              </div>
            </SettingItem>
          )}
          {platform === 'linux' && (
            <SettingItem title={t('mihomo.tproxyPort')} divider>
              <div className="flex">
                {isManualPortChange && tproxyPortInput !== tproxyPort && (
                  <Button
                    size="sm"
                    color="primary"
                    className="mr-2"
                    onPress={async () => {
                      await onChangeNeedRestart({ 'tproxy-port': tproxyPortInput })
                    }}
                  >
                    {t('mihomo.confirm')}
                  </Button>
                )}

                <Input
                  size="sm"
                  type="number"
                  className="w-25"
                  value={(showTproxyPort ?? tproxyPort ?? '').toString()}
                  max={65535}
                  min={0}
                  onValueChange={(v) => {
                    const port = v === '' ? 0 : parseInt(v)
                    if (!isNaN(port) && port >= 0 && port <= 65535) {
                      setTproxyPortInput(port)
                      patchAppConfig({ showTproxyPort: port })
                      setIsManualPortChange(true)
                    }
                  }}
                />
                <Button
                  isIconOnly
                  size="sm"
                  variant="light"
                  className="ml-2"
                  onPress={() => {
                    const randomPort = generateRandomPort()
                    setTproxyPortInput(randomPort)
                    patchAppConfig({ showTproxyPort: randomPort })
                    setIsManualPortChange(true)
                  }}
                >
                  <IoMdShuffle className="text-lg" />
                </Button>
                <Switch
                  size="sm"
                  className="ml-2"
                  isSelected={enableTproxyPort}
                  onValueChange={(value) => {
                    patchAppConfig({ enableTproxyPort: value })
                    if (value) {
                      const port = appConfig?.showTproxyPort ?? tproxyPort
                      onChangeNeedRestart({ 'tproxy-port': port })
                    } else {
                      onChangeNeedRestart({ 'tproxy-port': 0 })
                    }
                  }}
                />
              </div>
            </SettingItem>
          )}
          <SettingItem title={t('mihomo.externalController')} divider>
            <div className="flex">
              {externalControllerInput !== externalController && !externalControllerError && (
                <Button
                  size="sm"
                  color="primary"
                  className="mr-2"
                  isDisabled={!!externalControllerError}
                  onPress={() => {
                    onChangeNeedRestart({
                      'external-controller': externalControllerInput
                    })
                  }}
                >
                  {t('mihomo.confirm')}
                </Button>
              )}

              <Tooltip
                content={externalControllerError}
                placement="right"
                isOpen={!!externalControllerError}
                showArrow={true}
                color="danger"
                offset={10}
              >
                <Input
                  size="sm"
                  className={`w-50 ${externalControllerError ? 'border-red-500 ring-1 ring-red-500 rounded-lg' : ''}`}
                  value={externalControllerInput}
                  onValueChange={(v) => {
                    setExternalControllerInput(v)
                    const result = isValidListenAddress(v)
                    setExternalControllerError(
                      isValid(result) ? null : (getError(result) ?? '格式错误')
                    )
                  }}
                />
              </Tooltip>
            </div>
          </SettingItem>
          <SettingItem
            title={t('mihomo.externalControllerSecret')}
            actions={
              <Button
                size="sm"
                isIconOnly
                title={t('common.generateSecret')}
                variant="light"
                onPress={() => {
                  const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789'
                  const randomSecret = Array.from(
                    { length: 8 },
                    () => chars[Math.floor(Math.random() * chars.length)]
                  ).join('')
                  setSecretInput(randomSecret)
                }}
              >
                <IoMdRefresh className="text-lg" />
              </Button>
            }
            divider
          >
            <div className="flex">
              {secretInput !== secret && (
                <Button
                  size="sm"
                  color="primary"
                  className="mr-2"
                  onPress={() => {
                    onChangeNeedRestart({ secret: secretInput })
                  }}
                >
                  {t('mihomo.confirm')}
                </Button>
              )}

              <Input
                size="sm"
                type={isSecretVisible ? 'text' : 'password'}
                className="w-50"
                value={secretInput}
                onValueChange={(v) => {
                  setSecretInput(v)
                }}
                startContent={
                  <button
                    type="button"
                    onClick={() => setIsSecretVisible((prev) => !prev)}
                    className="text-gray-500 hover:text-gray-700"
                  >
                    {isSecretVisible ? (
                      <IoMdEyeOff className="w-4 h-4" />
                    ) : (
                      <IoMdEye className="w-4 h-4" />
                    )}
                  </button>
                }
              />
            </div>
          </SettingItem>
          <SettingItem title={t('settings.webui.title')} divider>
            <div className="flex gap-2">
              <Button
                size="sm"
                color="primary"
                isDisabled={!externalController || externalController.trim() === ''}
                onPress={() => setIsWebUIModalOpen(true)}
              >
                {t('settings.webui.manage')}
              </Button>
            </div>
          </SettingItem>
          <SettingItem title={t('mihomo.ipv6')} divider>
            <Switch
              size="sm"
              isSelected={ipv6}
              onValueChange={(v) => {
                onChangeNeedRestart({ ipv6: v })
              }}
            />
          </SettingItem>
          <SettingItem
            title={t('mihomo.allowLanConnection')}
            actions={
              <Button
                size="sm"
                isIconOnly
                variant="light"
                onPress={() => {
                  setLanOpen(true)
                }}
              >
                <FaNetworkWired className="text-lg" />
              </Button>
            }
            divider
          >
            <Switch
              size="sm"
              isSelected={allowLan}
              onValueChange={(v) => {
                onChangeNeedRestart({ 'allow-lan': v })
              }}
            />
          </SettingItem>
          {allowLan && (
            <>
              <SettingItem title={t('mihomo.allowedIpSegments')}>
                {JSON.stringify(lanAllowedIpsInput) !== JSON.stringify(lanAllowedIps) && (
                  <Button
                    size="sm"
                    color="primary"
                    onPress={() => {
                      onChangeNeedRestart({ 'lan-allowed-ips': lanAllowedIpsInput })
                    }}
                  >
                    {t('mihomo.confirm')}
                  </Button>
                )}
              </SettingItem>
              <div className="flex flex-col items-stretch mt-2">
                {[...lanAllowedIpsInput, ''].map((ipcidr, index) => {
                  return (
                    <div key={index} className="flex mb-2">
                      <Input
                        size="sm"
                        fullWidth
                        placeholder={t('mihomo.ipSegment.placeholder')}
                        value={ipcidr || ''}
                        onValueChange={(v) => {
                          if (index === lanAllowedIpsInput.length) {
                            setLanAllowedIpsInput([...lanAllowedIpsInput, v])
                          } else {
                            setLanAllowedIpsInput(
                              lanAllowedIpsInput.map((a, i) => (i === index ? v : a))
                            )
                          }
                        }}
                      />
                      {index < lanAllowedIpsInput.length && (
                        <Button
                          className="ml-2"
                          size="sm"
                          variant="flat"
                          color="warning"
                          onPress={() =>
                            setLanAllowedIpsInput(lanAllowedIpsInput.filter((_, i) => i !== index))
                          }
                        >
                          <MdDeleteForever className="text-lg" />
                        </Button>
                      )}
                    </div>
                  )
                })}
              </div>
              <Divider className="mb-2" />
              <SettingItem title={t('mihomo.disallowedIpSegments')}>
                {JSON.stringify(lanDisallowedIpsInput) !== JSON.stringify(lanDisallowedIps) && (
                  <Button
                    size="sm"
                    color="primary"
                    onPress={() => {
                      onChangeNeedRestart({ 'lan-disallowed-ips': lanDisallowedIpsInput })
                    }}
                  >
                    {t('mihomo.confirm')}
                  </Button>
                )}
              </SettingItem>
              <div className="flex flex-col items-stretch mt-2">
                {[...lanDisallowedIpsInput, ''].map((ipcidr, index) => {
                  return (
                    <div key={index} className="flex mb-2">
                      <Input
                        size="sm"
                        fullWidth
                        placeholder={t('mihomo.ipSegment.placeholder')}
                        value={ipcidr || ''}
                        onValueChange={(v) => {
                          if (index === lanDisallowedIpsInput.length) {
                            setLanDisallowedIpsInput([...lanDisallowedIpsInput, v])
                          } else {
                            setLanDisallowedIpsInput(
                              lanDisallowedIpsInput.map((a, i) => (i === index ? v : a))
                            )
                          }
                        }}
                      />
                      {index < lanDisallowedIpsInput.length && (
                        <Button
                          className="ml-2"
                          size="sm"
                          variant="flat"
                          color="warning"
                          onPress={() =>
                            setLanDisallowedIpsInput(
                              lanDisallowedIpsInput.filter((_, i) => i !== index)
                            )
                          }
                        >
                          <MdDeleteForever className="text-lg" />
                        </Button>
                      )}
                    </div>
                  )
                })}
              </div>
              <Divider className="mb-2" />
            </>
          )}
          <SettingItem title={t('mihomo.userVerification')}>
            {JSON.stringify(authenticationInput) !== JSON.stringify(authentication) && (
              <Button
                size="sm"
                color="primary"
                onPress={() => {
                  onChangeNeedRestart({ authentication: authenticationInput })
                }}
              >
                {t('mihomo.confirm')}
              </Button>
            )}
          </SettingItem>
          <div className="flex flex-col items-stretch mt-2">
            {[...authenticationInput, ''].map((auth, index) => {
              const [user, pass] = auth.split(':')
              return (
                <div key={index} className="flex mb-2">
                  <div className="flex-4">
                    <Input
                      size="sm"
                      fullWidth
                      placeholder={t('mihomo.username.placeholder')}
                      value={user || ''}
                      onValueChange={(v) => {
                        if (index === authenticationInput.length) {
                          setAuthenticationInput([...authenticationInput, `${v}:${pass || ''}`])
                        } else {
                          setAuthenticationInput(
                            authenticationInput.map((a, i) =>
                              i === index ? `${v}:${pass || ''}` : a
                            )
                          )
                        }
                      }}
                    />
                  </div>
                  <span className="mx-2">:</span>
                  <div className="flex-6 flex">
                    <Input
                      size="sm"
                      fullWidth
                      placeholder={t('mihomo.password.placeholder')}
                      value={pass || ''}
                      onValueChange={(v) => {
                        if (index === authenticationInput.length) {
                          setAuthenticationInput([...authenticationInput, `${user || ''}:${v}`])
                        } else {
                          setAuthenticationInput(
                            authenticationInput.map((a, i) =>
                              i === index ? `${user || ''}:${v}` : a
                            )
                          )
                        }
                      }}
                    />
                    {index < authenticationInput.length && (
                      <Button
                        className="ml-2"
                        size="sm"
                        variant="flat"
                        color="warning"
                        onPress={() =>
                          setAuthenticationInput(authenticationInput.filter((_, i) => i !== index))
                        }
                      >
                        <MdDeleteForever className="text-lg" />
                      </Button>
                    )}
                  </div>
                </div>
              )
            })}
          </div>
          <Divider className="mb-2" />
          <SettingItem title={t('mihomo.skipAuthPrefixes')}>
            {JSON.stringify(skipAuthPrefixesInput) !== JSON.stringify(skipAuthPrefixes) && (
              <Button
                size="sm"
                color="primary"
                onPress={() => {
                  onChangeNeedRestart({ 'skip-auth-prefixes': skipAuthPrefixesInput })
                }}
              >
                {t('mihomo.confirm')}
              </Button>
            )}
          </SettingItem>
          <div className="flex flex-col items-stretch mt-2">
            {[...skipAuthPrefixesInput, ''].map((ipcidr, index) => {
              return (
                <div key={index} className="flex mb-2">
                  <Input
                    disabled={index === 0 || index === 1}
                    size="sm"
                    fullWidth
                    placeholder={t('mihomo.ipSegment.placeholder')}
                    value={ipcidr || ''}
                    onValueChange={(v) => {
                      if (index === skipAuthPrefixesInput.length) {
                        setSkipAuthPrefixesInput([...skipAuthPrefixesInput, v])
                      } else {
                        setSkipAuthPrefixesInput(
                          skipAuthPrefixesInput.map((a, i) => (i === index ? v : a))
                        )
                      }
                    }}
                  />
                  {index < skipAuthPrefixesInput.length && index !== 0 && index !== 1 && (
                    <Button
                      className="ml-2"
                      size="sm"
                      variant="flat"
                      color="warning"
                      onPress={() =>
                        setSkipAuthPrefixesInput(
                          skipAuthPrefixesInput.filter((_, i) => i !== index)
                        )
                      }
                    >
                      <MdDeleteForever className="text-lg" />
                    </Button>
                  )}
                </div>
              )
            })}
          </div>
          <Divider className="mb-2" />
          <SettingItem title={t('mihomo.storeFakeIp')} divider>
            <Switch
              size="sm"
              isSelected={storeFakeIp}
              onValueChange={(v) => {
                onChangeNeedRestart({ profile: { 'store-fake-ip': v } })
              }}
            />
          </SettingItem>

          <SettingItem title={t('mihomo.logRetentionDays')} divider>
            <Input
              size="sm"
              type="number"
              className="w-25"
              value={maxLogDays.toString()}
              onValueChange={(v) => {
                const num = parseInt(v)
                if (!isNaN(num)) {
                  patchAppConfig({ maxLogDays: num })
                }
              }}
            />
          </SettingItem>
          <SettingItem title={t('mihomo.logFileSizeLimit')} divider>
            <Input
              size="sm"
              type="number"
              className="w-25"
              value={maxLogFileSize.toString()}
              onValueChange={(v) => {
                const num = parseInt(v)
                if (!isNaN(num)) {
                  patchAppConfig({ maxLogFileSize: num })
                }
              }}
              onBlur={(e) => {
                const num = parseInt(e.target.value)
                if (isNaN(num) || num < 1) {
                  patchAppConfig({ maxLogFileSize: 1 })
                }
              }}
            />
          </SettingItem>
          <SettingItem title={t('mihomo.logLevel')}>
            <Select
              classNames={{ trigger: 'data-[hover=true]:bg-default-200' }}
              className="w-25"
              size="sm"
              aria-label={t('mihomo.selectLogLevel')}
              selectedKeys={new Set([logLevel])}
              disallowEmptySelection={true}
              onSelectionChange={(v) => {
                onChangeNeedRestart({ 'log-level': v.currentKey as LogLevel })
              }}
            >
              <SelectItem key="silent">{t('mihomo.silent')}</SelectItem>
              <SelectItem key="error">{t('mihomo.error')}</SelectItem>
              <SelectItem key="warning">{t('mihomo.warning')}</SelectItem>
              <SelectItem key="info">{t('mihomo.info')}</SelectItem>
              <SelectItem key="debug">{t('mihomo.debug')}</SelectItem>
            </Select>
          </SettingItem>
        </SettingCard>
      </BasePage>

      {/* WebUI 管理模态框 */}
      <Modal
        isOpen={isWebUIModalOpen}
        onOpenChange={setIsWebUIModalOpen}
        size="5xl"
        scrollBehavior="inside"
        backdrop="blur"
        classNames={{ backdrop: 'top-[48px]' }}
        hideCloseButton
      >
        <ModalContent className="h-full w-[calc(100%-100px)]">
          <ModalHeader className="flex pb-0 app-drag">{t('settings.webui.manage')}</ModalHeader>
          <ModalBody className="flex flex-col h-full">
            <div className="flex flex-col h-full">
              {/* 添加/编辑面板表单 */}
              <div className="flex flex-col gap-2 p-3 bg-default-100 rounded-lg shrink-0">
                <Input
                  label={t('settings.webui.panelName')}
                  placeholder={t('settings.webui.panelNamePlaceholder')}
                  value={newPanelName}
                  onValueChange={setNewPanelName}
                />
                <Input
                  ref={urlInputRef}
                  label={t('settings.webui.panelUrl')}
                  placeholder={t('settings.webui.panelUrlPlaceholder')}
                  value={newPanelUrl}
                  onValueChange={setNewPanelUrl}
                />
                <div className="text-xs text-default-500">
                  {t('settings.webui.variableHint')}:
                  <ClickableVariableTag variable="%host" onClick={insertVariableAtCursor} />
                  <ClickableVariableTag variable="%port" onClick={insertVariableAtCursor} />
                  <ClickableVariableTag variable="%secret" onClick={insertVariableAtCursor} />
                </div>
                <div className="flex gap-2">
                  {editingPanel ? (
                    <>
                      <Button
                        size="sm"
                        color="primary"
                        onPress={updatePanel}
                        isDisabled={!newPanelName || !newPanelUrl}
                      >
                        {t('common.save')}
                      </Button>
                      <Button size="sm" color="default" variant="bordered" onPress={cancelEditing}>
                        {t('common.cancel')}
                      </Button>
                    </>
                  ) : (
                    <Button
                      size="sm"
                      color="primary"
                      onPress={addNewPanel}
                      isDisabled={!newPanelName || !newPanelUrl}
                    >
                      {t('settings.webui.addPanel')}
                    </Button>
                  )}
                  <Button
                    size="sm"
                    color="warning"
                    variant="bordered"
                    onPress={restoreDefaultPanels}
                  >
                    {t('settings.webui.restoreDefaults')}
                  </Button>
                </div>
              </div>

              {/* 面板列表 */}
              <div className="flex flex-col gap-2 mt-2 overflow-y-auto grow">
                <h3 className="text-lg font-semibold">{t('settings.webui.panels')}</h3>
                {allPanels.map((panel) => (
                  <div
                    key={panel.id}
                    className="flex items-start justify-between p-3 bg-default-50 rounded-lg shrink-0"
                  >
                    <div className="flex-1 mr-2">
                      <p className="font-medium">{panel.name}</p>
                      <HighlightedUrl url={panel.url} />
                    </div>
                    <div className="flex gap-2">
                      <Button isIconOnly size="sm" color="primary" onPress={() => openWebUI(panel)}>
                        <MdOpenInNew />
                      </Button>
                      <Button
                        isIconOnly
                        size="sm"
                        color="warning"
                        onPress={() => startEditing(panel)}
                      >
                        <MdEdit />
                      </Button>
                      <Button
                        isIconOnly
                        size="sm"
                        color="danger"
                        onPress={() => deletePanel(panel.id)}
                      >
                        <MdDelete />
                      </Button>
                    </div>
                  </div>
                ))}
              </div>
            </div>
          </ModalBody>
          <ModalFooter className="pt-0">
            <Button color="primary" onPress={() => setIsWebUIModalOpen(false)}>
              {t('common.close')}
            </Button>
          </ModalFooter>
        </ModalContent>
      </Modal>
    </>
  )
}

export default Mihomo
