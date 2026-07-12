import { Button, Tooltip } from '@heroui/react'
import { createHeapSnapshot, quitApp, quitWithoutCore, resetAppConfig } from '@renderer/utils/ipc'
import { useState } from 'react'
import { version } from '@renderer/utils/init'
import { IoIosHelpCircle } from 'react-icons/io'
import { getDriver } from '@renderer/App'
import { useTranslation } from 'react-i18next'
import SettingItem from '../base/base-setting-item'
import SettingCard from '../base/base-setting-card'
import BaseConfirmModal from '../base/base-confirm-modal'
import { toast } from '../base/toast'

const Actions: React.FC = () => {
  const { t } = useTranslation()
  const [showResetConfirm, setShowResetConfirm] = useState(false)

  return (
    <>
      {showResetConfirm && (
        <BaseConfirmModal
          isOpen={showResetConfirm}
          title={t('actions.reset.confirm.title')}
          content={t('actions.reset.confirm.content')}
          onCancel={() => setShowResetConfirm(false)}
          onConfirm={async () => {
            try {
              await resetAppConfig()
              setShowResetConfirm(false)
            } catch (error) {
              toast.error(String(error))
            }
          }}
        />
      )}
      <SettingCard>
        <SettingItem title={t('actions.guide.title')} divider>
          <Button size="sm" onPress={() => getDriver()?.drive()}>
            {t('actions.guide.button')}
          </Button>
        </SettingItem>
        <SettingItem
          title={t('actions.reset.title')}
          actions={
            <Tooltip content={t('actions.reset.tooltip')}>
              <Button isIconOnly size="sm" variant="light">
                <IoIosHelpCircle className="text-lg" />
              </Button>
            </Tooltip>
          }
          divider
        >
          <Button size="sm" onPress={() => setShowResetConfirm(true)}>
            {t('actions.reset.button')}
          </Button>
        </SettingItem>
        <SettingItem
          title={t('actions.heapSnapshot.title')}
          actions={
            <Tooltip content={t('actions.heapSnapshot.tooltip')}>
              <Button isIconOnly size="sm" variant="light">
                <IoIosHelpCircle className="text-lg" />
              </Button>
            </Tooltip>
          }
          divider
        >
          <Button size="sm" onPress={createHeapSnapshot}>
            {t('actions.heapSnapshot.button')}
          </Button>
        </SettingItem>
        <SettingItem
          title={t('actions.lightMode.title')}
          actions={
            <Tooltip content={t('actions.lightMode.tooltip')}>
              <Button isIconOnly size="sm" variant="light">
                <IoIosHelpCircle className="text-lg" />
              </Button>
            </Tooltip>
          }
          divider
        >
          <Button size="sm" onPress={quitWithoutCore}>
            {t('actions.lightMode.button')}
          </Button>
        </SettingItem>
        <SettingItem title={t('actions.quit.title')} divider>
          <Button size="sm" onPress={quitApp}>
            {t('actions.quit.button')}
          </Button>
        </SettingItem>
        <SettingItem title={t('actions.version.title')}>
          <div>v{version}</div>
        </SettingItem>
      </SettingCard>
    </>
  )
}

export default Actions
