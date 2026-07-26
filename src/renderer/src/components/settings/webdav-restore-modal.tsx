import { Modal, ModalContent, ModalHeader, ModalBody, ModalFooter, Button } from '@heroui/react'
import { toast } from '@renderer/components/base/toast'
import { relaunchApp, webdavDelete, webdavRestore } from '@renderer/utils/ipc'
import React, { useState } from 'react'
import { MdDeleteForever } from 'react-icons/md'
import { useTranslation } from 'react-i18next'
import BaseConfirmModal from '../base/base-confirm-modal'

interface Props {
  filenames: string[]
  onClose: () => void
}

const WebdavRestoreModal: React.FC<Props> = (props) => {
  const { t } = useTranslation()
  const { filenames: names, onClose } = props
  const [filenames, setFilenames] = useState<string[]>(names)
  const [restoring, setRestoring] = useState(false)
  const [pendingRestore, setPendingRestore] = useState<string | null>(null)

  // 恢复会用远端归档替换掉本机全部配置（包括代理配置），且随后立即重启应用。
  // 归档本身来自 WebDAV 服务器，而 webdavIgnoreCert 允许关闭证书校验，
  // 所以这一步必须由用户明确确认，和本地导入保持一致。
  const runRestore = async (filename: string): Promise<void> => {
    setPendingRestore(null)
    setRestoring(true)
    try {
      await webdavRestore(filename)
      await relaunchApp()
    } catch (e) {
      toast.error(t('common.error.restoreFailed', { error: e }))
    } finally {
      setRestoring(false)
    }
  }

  return (
    <>
      {pendingRestore !== null && (
        <BaseConfirmModal
          isOpen
          title={t('webdav.restore.confirm.title')}
          content={t('webdav.restore.confirm.body', { filename: pendingRestore })}
          onCancel={() => setPendingRestore(null)}
          onConfirm={() => void runRestore(pendingRestore)}
        />
      )}
      <Modal
        backdrop="blur"
        classNames={{ backdrop: 'top-[48px]' }}
        hideCloseButton
        isOpen={true}
        onOpenChange={onClose}
        scrollBehavior="inside"
      >
        <ModalContent>
          <ModalHeader className="flex app-drag">{t('webdav.restore.title')}</ModalHeader>
          <ModalBody>
            {filenames.length === 0 ? (
              <div className="flex justify-center">{t('webdav.restore.noBackups')}</div>
            ) : (
              filenames
                .sort()
                .reverse()
                .map((filename) => (
                  <div className="flex" key={filename}>
                    <Button
                      size="sm"
                      fullWidth
                      isLoading={restoring}
                      variant="flat"
                      onPress={() => setPendingRestore(filename)}
                    >
                      {filename}
                    </Button>
                    <Button
                      size="sm"
                      color="warning"
                      variant="flat"
                      className="ml-2"
                      onPress={async () => {
                        try {
                          await webdavDelete(filename)
                          setFilenames(filenames.filter((name) => name !== filename))
                        } catch (e) {
                          toast.error(t('common.error.deleteFailed', { error: e }))
                        }
                      }}
                    >
                      <MdDeleteForever className="text-lg" />
                    </Button>
                  </div>
                ))
            )}
          </ModalBody>
          <ModalFooter>
            <Button size="sm" variant="light" onPress={onClose}>
              {t('common.close')}
            </Button>
          </ModalFooter>
        </ModalContent>
      </Modal>
    </>
  )
}

export default WebdavRestoreModal
