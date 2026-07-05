import SettingCard from '@renderer/components/base/base-setting-card'
import SettingItem from '@renderer/components/base/base-setting-item'
import { useTranslation } from 'react-i18next'

/**
 * sing-box 内核不使用 mihomo 格式的 geodata（.mmdb/.dat）。
 * GEOSITE / GEOIP 规则在配置转换时映射为 sing-box 远程 rule-set
 * （MetaCubeX/meta-rules-dat 的 sing 分支 .srs 文件），由内核按需下载并缓存。
 */
const GeoData: React.FC = () => {
  const { t } = useTranslation()

  return (
    <SettingCard>
      <SettingItem title={t('resources.geoData.mode')}>
        <span className="text-default-500 text-sm text-right">
          GEOSITE / GEOIP → sing-box remote rule-set (.srs, MetaCubeX/meta-rules-dat)
        </span>
      </SettingItem>
      <div className="mt-2 text-xs text-default-400">
        Rule-sets are downloaded and cached automatically by the sing-box core. No local geodata
        files are used.
      </div>
    </SettingCard>
  )
}

export default GeoData
