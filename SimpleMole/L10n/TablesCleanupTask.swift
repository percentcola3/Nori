import Foundation

/// The centered cleanup stage uses the same keys in every supported language.
/// Progress counts handled targets; completion reports confirmed reclaimed space.
enum L10nCleanupTaskTables {
    static let adminKeys = ["cleanup.admin.title", "cleanup.admin.message", "cleanup.admin.include", "cleanup.admin.skip"]
    static let scanKeys = ["scan.partial.message", "scan.reason.access", "scan.reason.changed",
        "scan.reason.read", "scan.reason.otherVolume", "scan.reason.cancelled", "scan.reason.more", "scan.reason.unknown"]
    static let keys = [
        "cleanup.task.preparing", "cleanup.task.cleaning", "cleanup.task.verifying",
        "cleanup.task.progress", "cleanup.task.success", "cleanup.task.completed",
        "cleanup.task.retry", "cleanup.task.review", "cleanup.task.closeApps",
        "cleanup.task.reclaimed", "cleanup.task.failed",
        "cleanup.progress.discovery", "cleanup.progress.occupancy",
        "cleanup.progress.deepPhase", "cleanup.progress.directories"
    ]

    private static let translations: [AppLanguage: [String]] = [
        .en: [
            "Preparing cleanup…", "Cleaning…", "Verifying cleanup…",
            "Processed %d of %d targets", "Cleanup complete", "Items cleaned: %d",
            "Retry cleanup", "Review remaining items",
            "Save your work and fully quit %@, then retry cleanup.",
            "Cleaned %@", "Cleanup failed",
            "Finding cache folders…", "Checking files in use…", "Full-depth scan · %@", "Checked %d/%d folders"
        ],
        .zhHans: [
            "正在准备清理…", "正在清理…", "正在验证清理结果…",
            "已处理 %d/%d 个目标", "清理完成", "已清理 %d 个项目",
            "再次清理", "查看剩余项目", "请先保存工作并完全退出 %@，然后再次清理。",
            "清理了 %@", "清理失败",
            "正在查找缓存目录…", "正在检查文件占用…", "深度扫描 · %@", "已扫描 %d/%d 个目录"
        ],
        .zhHant: [
            "正在準備清理…", "正在清理…", "正在驗證清理結果…",
            "已處理 %d/%d 個目標", "清理完成", "已清理 %d 個項目",
            "再次清理", "查看剩餘項目", "請先儲存工作並完全結束 %@，然後再次清理。",
            "清理了 %@", "清理失敗",
            "正在尋找快取目錄…", "正在檢查檔案佔用…", "深度掃描 · %@", "已掃描 %d/%d 個目錄"
        ],
        .ja: [
            "クリーンアップを準備中…", "クリーンアップ中…", "クリーンアップ結果を確認中…",
            "処理済みの対象: %d/%d", "クリーンアップ完了", "クリーンアップした項目: %d",
            "再度クリーンアップ", "残りの項目を確認",
            "作業を保存して %@ を完全に終了し、クリーンアップを再試行してください。",
            "%@ をクリーンアップしました", "クリーンアップに失敗しました",
            "キャッシュフォルダを検索中…", "使用中のファイルを確認中…", "詳細スキャン · %@", "%d/%d フォルダを確認済み"
        ],
        .ko: [
            "정리 준비 중…", "정리 중…", "정리 결과 확인 중…",
            "처리한 대상: %d/%d", "정리 완료", "정리한 항목: %d개",
            "다시 정리", "남은 항목 확인",
            "작업을 저장하고 %@을(를) 완전히 종료한 후 다시 정리하세요.",
            "%@ 정리됨", "정리 실패",
            "캐시 폴더 찾는 중…", "사용 중인 파일 확인 중…", "심층 검사 · %@", "폴더 %d/%d개 확인됨"
        ],
        .de: [
            "Bereinigung wird vorbereitet…", "Bereinigung läuft…", "Bereinigung wird geprüft…",
            "%d von %d Zielen verarbeitet", "Bereinigung abgeschlossen", "Bereinigte Elemente: %d",
            "Bereinigung wiederholen", "Verbleibende Elemente prüfen",
            "Speichere deine Arbeit und beende %@ vollständig. Wiederhole dann die Bereinigung.",
            "%@ bereinigt", "Bereinigung fehlgeschlagen",
            "Cache-Ordner werden gesucht…", "Verwendete Dateien werden geprüft…", "Vollständiger Scan · %@", "%d/%d Ordner geprüft"
        ],
        .fr: [
            "Préparation du nettoyage…", "Nettoyage en cours…", "Vérification du nettoyage…",
            "%d cibles traitées sur %d", "Nettoyage terminé", "Éléments nettoyés : %d",
            "Réessayer le nettoyage", "Examiner les éléments restants",
            "Enregistre ton travail et quitte complètement %@, puis réessaie le nettoyage.",
            "%@ nettoyés", "Échec du nettoyage",
            "Recherche des dossiers de cache…", "Vérification des fichiers utilisés…", "Analyse approfondie · %@", "%d/%d dossiers vérifiés"
        ],
        .es: [
            "Preparando la limpieza…", "Limpiando…", "Verificando la limpieza…",
            "%d de %d objetivos procesados", "Limpieza completada", "Elementos limpiados: %d",
            "Reintentar limpieza", "Revisar elementos restantes",
            "Guarda tu trabajo y cierra completamente %@. Después, vuelve a intentar la limpieza.",
            "%@ limpiados", "La limpieza falló",
            "Buscando carpetas de caché…", "Comprobando archivos en uso…", "Análisis completo · %@", "%d/%d carpetas comprobadas"
        ],
        .pt: [
            "Preparando a limpeza…", "Limpando…", "Verificando a limpeza…",
            "%d de %d alvos processados", "Limpeza concluída", "Itens limpos: %d",
            "Tentar limpar novamente", "Revisar itens restantes",
            "Salve seu trabalho e encerre completamente %@. Depois, tente limpar novamente.",
            "%@ limpos", "Falha na limpeza",
            "Procurando pastas de cache…", "Verificando arquivos em uso…", "Verificação completa · %@", "%d/%d pastas verificadas"
        ],
        .it: [
            "Preparazione della pulizia…", "Pulizia in corso…", "Verifica della pulizia…",
            "%d di %d obiettivi elaborati", "Pulizia completata", "Elementi puliti: %d",
            "Riprova la pulizia", "Esamina gli elementi rimanenti",
            "Salva il lavoro ed esci completamente da %@, poi riprova la pulizia.",
            "%@ puliti", "Pulizia non riuscita",
            "Ricerca delle cartelle cache…", "Controllo dei file in uso…", "Scansione completa · %@", "%d/%d cartelle controllate"
        ],
        .ru: [
            "Подготовка к очистке…", "Очистка…", "Проверка результатов очистки…",
            "Обработано объектов: %d из %d", "Очистка завершена", "Очищено элементов: %d",
            "Повторить очистку", "Просмотреть оставшиеся элементы",
            "Сохраните работу и полностью закройте %@, затем повторите очистку.",
            "Очищено %@", "Очистка не удалась",
            "Поиск папок кэша…", "Проверка используемых файлов…", "Полное сканирование · %@", "Проверено папок: %d/%d"
        ],
        .tr: [
            "Temizleme hazırlanıyor…", "Temizleniyor…", "Temizleme doğrulanıyor…",
            "%d/%d hedef işlendi", "Temizleme tamamlandı", "Temizlenen öğe: %d",
            "Temizlemeyi yeniden dene", "Kalan öğeleri incele",
            "Çalışmanı kaydet ve %@ uygulamalarından tamamen çık, ardından temizlemeyi yeniden dene.",
            "%@ temizlendi", "Temizleme başarısız",
            "Önbellek klasörleri aranıyor…", "Kullanılan dosyalar denetleniyor…", "Tam tarama · %@", "%d/%d klasör denetlendi"
        ]
    ]

    static func table(for language: AppLanguage) -> [String: String] {
        guard let values = translations[language], values.count == keys.count else { return [:] }
        var table = Dictionary(uniqueKeysWithValues: zip(keys, values))
        let adminValues: [String]
        switch language {
        case .zhHans:
            adminValues = ["包含管理员清理项目？", "所选项目中有 %d 个需要管理员权限。包含这些项目时，macOS 将请求一次管理员授权；取消系统授权后不会自动重试。也可以跳过这些项目，只清理普通项目。", "包含管理员项目", "仅清理普通项目"]
        case .zhHant:
            adminValues = ["包含管理員清理項目？", "所選項目中有 %d 個需要管理員權限。包含這些項目時，macOS 將請求一次管理員授權；取消系統授權後不會自動重試。也可以跳過這些項目，只清理普通項目。", "包含管理員項目", "僅清理普通項目"]
        default:
            adminValues = ["Include administrator cleanup?", "%d selected items require administrator access. Including them requests administrator authorization once from macOS, without automatic retries if you cancel. You can skip them and clean ordinary items only.", "Include administrator items", "Clean ordinary items only"]
        }
        for (key, value) in zip(adminKeys, adminValues) { table[key] = value }
        let scanValues: [String]
        switch language {
        case .zhHans:
            scanValues = ["磁盘分析已返回可用结果，但部分目录未能扫描，容量统计可能偏小。请查看下方原因。",
                "目录访问受限。请检查完全磁盘访问授权和目录权限；系统保护的目录可能仍无法读取。",
                "文件或目录在扫描期间被移动或删除。请重新扫描。",
                "无法读取此位置。请检查目录是否可访问，并根据系统错误重试。",
                "此目录位于其他卷，本次扫描没有跨卷遍历。可选择该目录单独分析。",
                "扫描已取消，仅保留已完成的结果。", "另有 %d 个位置未能完整扫描。", "扫描未能覆盖所有目录，但扫描器没有返回具体错误。请重新扫描此位置。"]
        case .zhHant:
            scanValues = ["磁碟分析已傳回可用結果，但部分目錄未能掃描，容量統計可能偏小。請查看下方原因。",
                "目錄存取受限。請檢查完整磁碟存取授權與目錄權限；系統保護的目錄可能仍無法讀取。",
                "檔案或目錄在掃描期間被移動或刪除。請重新掃描。",
                "無法讀取此位置。請檢查目錄是否可存取，並根據系統錯誤重試。",
                "此目錄位於其他卷宗，本次掃描未跨卷宗遍歷。可選擇該目錄單獨分析。",
                "掃描已取消，僅保留已完成的結果。", "另有 %d 個位置未能完整掃描。", "掃描未涵蓋所有目錄，但掃描器未傳回具體錯誤。請重新掃描此位置。"]
        default:
            scanValues = ["Disk analysis returned usable results, but some folders could not be scanned. Sizes may be underestimated. Review the reasons below.",
                "Access to this location was denied. Check Full Disk Access and folder permissions; system-protected folders may remain inaccessible.",
                "This file or folder moved or disappeared during scanning. Scan again.",
                "This location could not be read. Check its availability and the system error before retrying.",
                "This folder is on another volume, which this traversal did not cross. Select it for a separate analysis.",
                "Scanning was canceled; only completed results are available.", "%d additional locations could not be fully scanned.", "Not all folders were covered, but the scanner returned no specific error. Scan this location again."]
        }
        for (key, value) in zip(scanKeys, scanValues) { table[key] = value }
        return table
    }
}
