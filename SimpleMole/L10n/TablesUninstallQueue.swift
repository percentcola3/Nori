import Foundation

/// Uninstall queue copy is kept in a feature table so every locale receives
/// the same state vocabulary without making the base navigation table harder
/// to audit.  Queue labels are intentionally short because they are rendered
/// inline in app rows and the current operation status.
enum L10nUninstallQueueTables {
    static let en: [String: String] = [
        "uninstall.retained": "Retained %d app data, shared, or system items for review:",
        "uninstall.remaining": "%d items could not be cleaned:",
        "uninstall.resultDetails": "View uninstall result and remaining files",
        "uninstall.loading": "Preparing app list…",
        "uninstall.queue.cancel": "Cancel",
        "uninstall.queue.waiting": "Queued · #%d",
        "uninstall.queue.queued": "Queued",
        "uninstall.queue.preparing": "Preparing",
        "uninstall.queue.running": "Removing…",
        "uninstall.queue.succeeded": "Completed",
        "uninstall.queue.failed": "Failed · try again",
        "uninstall.queue.retry": "Retry",
        "uninstall.queue.permissionLost": "Disk access authorization is no longer available. Authorize again before adding this app.",
    ]

    static let zhHans: [String: String] = [
        "uninstall.retained": "已保留 %d 项应用数据、共享或系统项目，供复核：",
        "uninstall.remaining": "以下 %d 项未能清理：",
        "uninstall.resultDetails": "查看卸载结果与保留文件",
        "uninstall.loading": "正在准备应用列表…",
        "uninstall.queue.cancel": "取消排队",
        "uninstall.queue.waiting": "排队中 · 第 %d 位",
        "uninstall.queue.queued": "排队中",
        "uninstall.queue.preparing": "准备中",
        "uninstall.queue.running": "清理中…",
        "uninstall.queue.succeeded": "已完成",
        "uninstall.queue.failed": "失败 · 可重试",
        "uninstall.queue.retry": "重试卸载",
        "uninstall.queue.permissionLost": "磁盘访问授权已失效，请重新授权后再添加此应用。",
    ]

    static let zhHant: [String: String] = [
        "uninstall.loading": "正在準備應用程式列表…",
        "uninstall.queue.cancel": "取消排隊",
        "uninstall.queue.waiting": "排隊中 · 第 %d 位",
        "uninstall.queue.queued": "排隊中",
        "uninstall.queue.preparing": "準備中",
        "uninstall.queue.running": "清理中…",
        "uninstall.queue.succeeded": "已完成",
        "uninstall.queue.failed": "失敗 · 可重試",
        "uninstall.queue.retry": "重試解除安裝",
        "uninstall.queue.permissionLost": "磁碟存取授權已失效，請重新授權後再加入此應用程式。",
    ]

    static let ja: [String: String] = [
        "uninstall.loading": "アプリ一覧を準備中…",
        "uninstall.queue.cancel": "待機を取り消す",
        "uninstall.queue.waiting": "待機中 · #%d",
        "uninstall.queue.queued": "待機中",
        "uninstall.queue.preparing": "準備中",
        "uninstall.queue.running": "削除中…",
        "uninstall.queue.succeeded": "完了",
        "uninstall.queue.failed": "失敗 · 再試行できます",
        "uninstall.queue.retry": "再試行",
        "uninstall.queue.permissionLost": "ディスクアクセスの許可が失効しました。もう一度許可してからアプリを追加してください。",
    ]

    static let ko: [String: String] = [
        "uninstall.loading": "앱 목록 준비 중…",
        "uninstall.queue.cancel": "대기 취소",
        "uninstall.queue.waiting": "대기 중 · #%d",
        "uninstall.queue.queued": "대기 중",
        "uninstall.queue.preparing": "준비 중",
        "uninstall.queue.running": "제거 중…",
        "uninstall.queue.succeeded": "완료",
        "uninstall.queue.failed": "실패 · 다시 시도",
        "uninstall.queue.retry": "다시 시도",
        "uninstall.queue.permissionLost": "디스크 접근 권한이 만료되었습니다. 다시 허용한 후 앱을 추가하세요.",
    ]

    static let de: [String: String] = [
        "uninstall.loading": "App-Liste wird vorbereitet…",
        "uninstall.queue.cancel": "Warten abbrechen",
        "uninstall.queue.waiting": "Wartet · Nr. %d",
        "uninstall.queue.queued": "Wartet",
        "uninstall.queue.preparing": "Wird vorbereitet",
        "uninstall.queue.running": "Wird entfernt…",
        "uninstall.queue.succeeded": "Abgeschlossen",
        "uninstall.queue.failed": "Fehlgeschlagen · erneut versuchen",
        "uninstall.queue.retry": "Erneut versuchen",
        "uninstall.queue.permissionLost": "Die Festplattenzugriffsfreigabe ist nicht mehr gültig. Erlaube den Zugriff erneut, bevor du diese App hinzufügst.",
    ]

    static let fr: [String: String] = [
        "uninstall.loading": "Préparation de la liste des apps…",
        "uninstall.queue.cancel": "Annuler l’attente",
        "uninstall.queue.waiting": "En attente · n° %d",
        "uninstall.queue.queued": "En attente",
        "uninstall.queue.preparing": "Préparation",
        "uninstall.queue.running": "Suppression…",
        "uninstall.queue.succeeded": "Terminé",
        "uninstall.queue.failed": "Échec · réessayer",
        "uninstall.queue.retry": "Réessayer",
        "uninstall.queue.permissionLost": "L’autorisation d’accès au disque n’est plus valide. Autorisez-la à nouveau avant d’ajouter cette app.",
    ]

    static let es: [String: String] = [
        "uninstall.loading": "Preparando la lista de apps…",
        "uninstall.queue.cancel": "Cancelar espera",
        "uninstall.queue.waiting": "En cola · n.º %d",
        "uninstall.queue.queued": "En cola",
        "uninstall.queue.preparing": "Preparando",
        "uninstall.queue.running": "Eliminando…",
        "uninstall.queue.succeeded": "Completado",
        "uninstall.queue.failed": "Error · reintentar",
        "uninstall.queue.retry": "Reintentar",
        "uninstall.queue.permissionLost": "La autorización de acceso al disco ya no está disponible. Autorízala de nuevo antes de añadir esta app.",
    ]

    static let pt: [String: String] = [
        "uninstall.loading": "Preparando a lista de apps…",
        "uninstall.queue.cancel": "Cancelar espera",
        "uninstall.queue.waiting": "Na fila · nº %d",
        "uninstall.queue.queued": "Na fila",
        "uninstall.queue.preparing": "Preparando",
        "uninstall.queue.running": "Removendo…",
        "uninstall.queue.succeeded": "Concluído",
        "uninstall.queue.failed": "Falha · tentar novamente",
        "uninstall.queue.retry": "Tentar novamente",
        "uninstall.queue.permissionLost": "A autorização de acesso ao disco não está mais disponível. Autorize novamente antes de adicionar este app.",
    ]

    static let it: [String: String] = [
        "uninstall.loading": "Preparazione dell’elenco delle app…",
        "uninstall.queue.cancel": "Annulla attesa",
        "uninstall.queue.waiting": "In coda · n. %d",
        "uninstall.queue.queued": "In coda",
        "uninstall.queue.preparing": "Preparazione",
        "uninstall.queue.running": "Rimozione…",
        "uninstall.queue.succeeded": "Completato",
        "uninstall.queue.failed": "Operazione non riuscita · riprova",
        "uninstall.queue.retry": "Riprova",
        "uninstall.queue.permissionLost": "L’autorizzazione per l’accesso al disco non è più disponibile. Autorizza di nuovo prima di aggiungere questa app.",
    ]

    static let ru: [String: String] = [
        "uninstall.loading": "Подготовка списка приложений…",
        "uninstall.queue.cancel": "Отменить ожидание",
        "uninstall.queue.waiting": "В очереди · № %d",
        "uninstall.queue.queued": "В очереди",
        "uninstall.queue.preparing": "Подготовка",
        "uninstall.queue.running": "Удаление…",
        "uninstall.queue.succeeded": "Завершено",
        "uninstall.queue.failed": "Ошибка · повторить",
        "uninstall.queue.retry": "Повторить",
        "uninstall.queue.permissionLost": "Разрешение на доступ к диску больше недоступно. Разрешите доступ снова перед добавлением приложения.",
    ]

    static let tr: [String: String] = [
        "uninstall.loading": "Uygulama listesi hazırlanıyor…",
        "uninstall.queue.cancel": "Beklemeyi iptal et",
        "uninstall.queue.waiting": "Sırada · #%d",
        "uninstall.queue.queued": "Sırada",
        "uninstall.queue.preparing": "Hazırlanıyor",
        "uninstall.queue.running": "Kaldırılıyor…",
        "uninstall.queue.succeeded": "Tamamlandı",
        "uninstall.queue.failed": "Başarısız · yeniden dene",
        "uninstall.queue.retry": "Yeniden dene",
        "uninstall.queue.permissionLost": "Disk erişimi yetkisi artık kullanılamıyor. Bu uygulamayı eklemeden önce yeniden izin verin.",
    ]

    static func table(for language: AppLanguage) -> [String: String] {
        switch language {
        case .zhHans: return zhHans
        case .zhHant: return zhHant
        case .en: return en
        case .ja: return ja
        case .ko: return ko
        case .de: return de
        case .fr: return fr
        case .es: return es
        case .pt: return pt
        case .it: return it
        case .ru: return ru
        case .tr: return tr
        case .auto: return [:]
        }
    }
}
