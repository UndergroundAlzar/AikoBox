import {
  Button,
  Checkbox,
  Divider,
  Dropdown,
  DropdownItem,
  DropdownMenu,
  DropdownTrigger,
  Input,
  Tooltip
} from '@heroui/react'
import BasePage from '@renderer/components/base/base-page'
import { toast } from '@renderer/components/base/toast'
import ProfileItem from '@renderer/components/profiles/profile-item'
import PluginItem from '@renderer/components/plugins/plugin-item'
import PluginInstallModal from '@renderer/components/plugins/plugin-install-modal'
import EditInfoModal from '@renderer/components/profiles/edit-info-modal'
import { useProfileConfig } from '@renderer/hooks/use-profile-config'
import { useAppConfig } from '@renderer/hooks/use-app-config'
import { usePluginConfig } from '@renderer/hooks/use-plugin-config'
import { showError } from '@renderer/utils/error-display'
import {
  addProfileItem as addProfileItemDirect,
  getFilePath,
  readTextFile,
  updatePluginProfile
} from '@renderer/utils/ipc'
import type { KeyboardEvent } from 'react'
import { useCallback, useEffect, useRef, useState } from 'react'
import { MdContentPaste, MdUnfoldMore, MdUnfoldLess } from 'react-icons/md'
import {
  DndContext,
  closestCenter,
  PointerSensor,
  useSensor,
  useSensors,
  DragEndEvent
} from '@dnd-kit/core'
import { SortableContext } from '@dnd-kit/sortable'
import { FaPlus } from 'react-icons/fa6'
import { IoMdRefresh } from 'react-icons/io'
import { useTranslation } from 'react-i18next'
import { runProfileBatchUpdate } from '@renderer/utils/profile-batch-update'

const Profiles: React.FC = () => {
  const { t } = useTranslation()
  const {
    profileConfig,
    setProfileConfig,
    addProfileItem,
    updateProfileItem,
    removeProfileItem,
    changeCurrentProfile,
    mutateProfileConfig
  } = useProfileConfig()
  const { appConfig, patchAppConfig } = useAppConfig()
  const { pluginUseProxy = false } = appConfig || {}
  const { current, items = [] } = profileConfig || {}
  const [sortedItems, setSortedItems] = useState(items)
  const [useProxy, setUseProxy] = useState(false)
  const [authToken, setAuthToken] = useState('')
  const [userAgent, setUserAgent] = useState('')
  const [ageSecretKey, setAgeSecretKey] = useState('')
  const [showAdvanced, setShowAdvanced] = useState(false)
  const [openInfoImport, setOpenInfoImport] = useState(false)
  const [importing, setImporting] = useState(false)
  const [updating, setUpdating] = useState(false)
  const importingRef = useRef(false)
  const updatingRef = useRef(false)
  const [fileOver, setFileOver] = useState(false)
  const [url, setUrl] = useState('')
  const [, setNow] = useState(new Date())
  const { pluginConfig, mutatePluginConfig } = usePluginConfig()
  const [showPluginImport, setShowPluginImport] = useState(false)
  const [pluginDropFile, setPluginDropFile] = useState<File | null>(null)
  // bump per .cpx drop -> remount modal so it loads the new file even when open
  const [pluginDropSeq, setPluginDropSeq] = useState(0)
  const isUrlEmpty = url.trim() === ''
  const sensors = useSensors(useSensor(PointerSensor))
  const handleImport = async (): Promise<void> => {
    if (importingRef.current || updatingRef.current) return
    importingRef.current = true
    setImporting(true)
    try {
      await addProfileItemDirect({
        name: '',
        type: 'remote',
        url,
        useProxy,
        authToken: authToken || undefined,
        userAgent: userAgent || undefined,
        ageSecretKey: ageSecretKey || undefined
      })
      mutateProfileConfig()
      window.electron.ipcRenderer.send('updateTrayMenu')
      setUrl('')
      setAuthToken('')
      setUserAgent('')
      setAgeSecretKey('')
      toast.success(t('profiles.notification.importSuccess'))
    } catch (error) {
      await showError(error, t('profiles.error.importFailed'))
    } finally {
      importingRef.current = false
      setImporting(false)
    }
  }
  const pageRef = useRef<HTMLDivElement>(null)

  const onDragEnd = async (event: DragEndEvent): Promise<void> => {
    if (updatingRef.current || importingRef.current) return
    const { active, over } = event
    if (over) {
      if (active.id !== over.id) {
        const newOrder = sortedItems.slice()
        const activeIndex = newOrder.findIndex((item) => item.id === active.id)
        const overIndex = newOrder.findIndex((item) => item.id === over.id)
        const [movedItem] = newOrder.splice(activeIndex, 1)
        newOrder.splice(overIndex, 0, movedItem)
        setSortedItems(newOrder)
        await setProfileConfig({ current, items: newOrder })
      }
    }
  }

  const handleImportRef = useRef(handleImport)
  handleImportRef.current = handleImport

  const addProfileItemRef = useRef(addProfileItem)
  addProfileItemRef.current = addProfileItem

  const tRef = useRef(t)
  tRef.current = t

  const handleInputKeyUp = useCallback((e: KeyboardEvent<HTMLInputElement>) => {
    if (e.key !== 'Enter' || e.currentTarget.value.trim() === '') return
    void handleImportRef.current()
  }, [])

  useEffect(() => {
    const element = pageRef.current
    if (!element) return

    const handleDragOver = (e: DragEvent): void => {
      e.preventDefault()
      e.stopPropagation()
      setFileOver(true)
    }

    const handleDragLeave = (e: DragEvent): void => {
      e.preventDefault()
      e.stopPropagation()
      setFileOver(false)
    }

    const handleDrop = async (event: DragEvent): Promise<void> => {
      event.preventDefault()
      event.stopPropagation()
      if (updatingRef.current || importingRef.current) {
        setFileOver(false)
        return
      }
      if (event.dataTransfer?.files) {
        const file = event.dataTransfer.files[0]
        const name = file?.name.toLowerCase() ?? ''
        if (name.endsWith('.yml') || name.endsWith('.yaml')) {
          try {
            const path = window.api.webUtils.getPathForFile(file)
            const content = await readTextFile(path)
            await addProfileItemRef.current({ name: file.name, type: 'local', file: content })
          } catch (e) {
            toast.error(String(e))
          }
        } else if (name.endsWith('.cpx')) {
          // .cpx -> plugin install modal (preview + confirm)
          setPluginDropFile(file)
          setPluginDropSeq((n) => n + 1)
          setShowPluginImport(true)
        } else if (file) {
          toast.warning(tRef.current('profiles.error.unsupportedFileType'))
        }
      }
      setFileOver(false)
    }

    element.addEventListener('dragover', handleDragOver)
    element.addEventListener('dragleave', handleDragLeave)
    element.addEventListener('drop', handleDrop)

    return (): void => {
      element.removeEventListener('dragover', handleDragOver)
      element.removeEventListener('dragleave', handleDragLeave)
      element.removeEventListener('drop', handleDrop)
    }
  }, [])

  useEffect(() => {
    const timer = setInterval(() => setNow(new Date()), 30000)
    return () => clearInterval(timer)
  }, [])

  useEffect(() => {
    setSortedItems(items)
  }, [items])

  return (
    <BasePage
      ref={pageRef}
      title={t('profiles.title')}
      header={
        <Button
          size="sm"
          title={t('profiles.updateAll')}
          className="app-nodrag"
          variant="light"
          isIconOnly
          isDisabled={updating}
          onPress={async () => {
            if (updatingRef.current || importingRef.current) return
            updatingRef.current = true
            setUpdating(true)
            try {
              const result = await runProfileBatchUpdate(items, current, async (item) => {
                if (item.type === 'remote') {
                  await addProfileItemDirect(item)
                  return
                }
                if (item.type === 'plugin' && item.pluginId) {
                  await updatePluginProfile(item.pluginId, true, true)
                }
              })
              mutateProfileConfig()
              window.electron.ipcRenderer.send('updateTrayMenu')

              if (result.total === 0) {
                toast.warning(t('profiles.notification.updateAllEmpty'))
              } else if (result.failed === 0) {
                toast.success(
                  t('profiles.notification.updateAllSuccess', { count: result.succeeded })
                )
              } else if (result.succeeded === 0) {
                toast.error(t('profiles.notification.updateAllFailed', { count: result.failed }))
              } else {
                toast.warning(
                  t('profiles.notification.updateAllPartial', {
                    succeeded: result.succeeded,
                    failed: result.failed
                  })
                )
              }
            } catch (error) {
              await showError(error, t('common.error.updateProfileFailed'))
            } finally {
              updatingRef.current = false
              setUpdating(false)
            }
          }}
        >
          <IoMdRefresh className={`text-lg ${updating ? 'animate-spin' : ''}`} />
        </Button>
      }
    >
      {openInfoImport && (
        <EditInfoModal
          mode="import"
          item={{
            id: '',
            name: '',
            type: 'remote',
            url: '',
            override: [],
            useProxy
          }}
          addProfileItem={addProfileItem}
          onClose={() => setOpenInfoImport(false)}
        />
      )}
      <div className="sticky profiles-sticky top-0 z-40 bg-background">
        <div className="flex flex-col gap-2 p-2">
          <div className="flex gap-2">
            <Input
              size="sm"
              placeholder={t('profiles.input.placeholder')}
              value={url}
              onValueChange={setUrl}
              onKeyUp={handleInputKeyUp}
              className="flex-1"
              endContent={
                <>
                  <Button
                    size="md"
                    isIconOnly
                    variant="light"
                    onPress={() => {
                      navigator.clipboard.readText().then((text) => {
                        setUrl(text)
                      })
                    }}
                    className="mr-2"
                  >
                    <MdContentPaste className="text-lg" />
                  </Button>
                  <Checkbox
                    className="whitespace-nowrap"
                    checked={useProxy}
                    onValueChange={setUseProxy}
                  >
                    {t('profiles.useProxy')}
                  </Checkbox>
                </>
              }
            />

            <Tooltip content={t('profiles.editInfo.authToken')} placement="bottom">
              <Button
                size="sm"
                variant={showAdvanced ? 'solid' : 'light'}
                isIconOnly
                onPress={() => setShowAdvanced(!showAdvanced)}
              >
                {showAdvanced ? (
                  <MdUnfoldLess className="text-lg" />
                ) : (
                  <MdUnfoldMore className="text-lg" />
                )}
              </Button>
            </Tooltip>
            <Button
              size="sm"
              color="primary"
              isDisabled={isUrlEmpty || updating}
              isLoading={importing}
              onPress={handleImport}
            >
              {t('profiles.import')}
            </Button>
            <Dropdown>
              <DropdownTrigger>
                <Button className="new-profile" size="sm" isIconOnly color="primary">
                  <FaPlus />
                </Button>
              </DropdownTrigger>
              <DropdownMenu
                onAction={async (key) => {
                  if (key === 'open') {
                    try {
                      const files = await getFilePath(['yml', 'yaml'])
                      if (files?.length) {
                        const content = await readTextFile(files[0])
                        const fileName = files[0].split('/').pop()?.split('\\').pop()
                        await addProfileItem({ name: fileName, type: 'local', file: content })
                      }
                    } catch (e) {
                      toast.error(String(e))
                    }
                  } else if (key === 'new') {
                    await addProfileItem({
                      name: t('profiles.newProfile'),
                      type: 'local',
                      file: 'proxies: []\nproxy-groups: []\nrules: []'
                    })
                  } else if (key === 'import') {
                    setOpenInfoImport(true)
                  }
                }}
              >
                <DropdownItem key="import">{t('profiles.import')}</DropdownItem>
                <DropdownItem key="open">{t('profiles.open')}</DropdownItem>
                <DropdownItem key="new">{t('profiles.new')}</DropdownItem>
              </DropdownMenu>
            </Dropdown>
          </div>
          {showAdvanced && (
            <div className="flex gap-2">
              <Input
                size="sm"
                type="password"
                placeholder={t('profiles.editInfo.authTokenPlaceholder')}
                value={authToken}
                onValueChange={setAuthToken}
                onKeyUp={handleInputKeyUp}
                className="flex-1"
              />
              <Input
                size="sm"
                placeholder={t('profiles.editInfo.userAgentPlaceholder')}
                value={userAgent}
                onValueChange={setUserAgent}
                onKeyUp={handleInputKeyUp}
                className="flex-1"
              />
              <Input
                size="sm"
                type="password"
                placeholder={t('profiles.editInfo.ageSecretKeyPlaceholder')}
                value={ageSecretKey}
                onValueChange={setAgeSecretKey}
                onKeyUp={handleInputKeyUp}
                className="flex-1"
              />
            </div>
          )}
        </div>
        <Divider />
      </div>
      <div className="px-2">
        <div className="flex items-center justify-between mt-2 mb-2">
          <span className="font-bold">{t('plugins.title')}</span>
          <div className="flex items-center gap-3">
            <Tooltip content={t('plugins.useProxyWarning')} placement="bottom">
              <Checkbox
                size="sm"
                isSelected={pluginUseProxy}
                onValueChange={(v) => patchAppConfig({ pluginUseProxy: v })}
              >
                {t('plugins.useProxy')}
              </Checkbox>
            </Tooltip>
            <Button
              size="sm"
              color="primary"
              isDisabled={updating || importing}
              onPress={() => setShowPluginImport(true)}
            >
              {t('plugins.import')}
            </Button>
          </div>
        </div>
        {(pluginConfig?.items?.length ?? 0) > 0 && (
          <div className="grid grid-cols-1 gap-2 mb-3">
            {pluginConfig?.items?.map((p) => (
              <PluginItem
                key={p.id}
                item={p}
                disabled={updating || importing}
                onChanged={mutatePluginConfig}
              />
            ))}
          </div>
        )}
        {showPluginImport && (
          <PluginInstallModal
            key={pluginDropSeq}
            initialFile={pluginDropFile ?? undefined}
            onClose={() => {
              setShowPluginImport(false)
              setPluginDropFile(null)
              mutatePluginConfig()
            }}
          />
        )}
      </div>
      <DndContext sensors={sensors} collisionDetection={closestCenter} onDragEnd={onDragEnd}>
        <div
          className={`${fileOver ? 'blur-sm' : ''} grid sm:grid-cols-2 md:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4 gap-2 m-2`}
        >
          <SortableContext
            items={sortedItems.map((item) => {
              return item.id
            })}
          >
            {sortedItems.map((item) => (
              <ProfileItem
                key={item.id}
                isCurrent={item.id === current}
                addProfileItem={addProfileItem}
                removeProfileItem={removeProfileItem}
                mutateProfileConfig={mutateProfileConfig}
                updateProfileItem={updateProfileItem}
                info={item}
                onPress={async () => {
                  if (updatingRef.current || importingRef.current) return
                  await changeCurrentProfile(item.id)
                }}
                disabled={updating || importing}
              />
            ))}
          </SortableContext>
        </div>
      </DndContext>
    </BasePage>
  )
}

export default Profiles
