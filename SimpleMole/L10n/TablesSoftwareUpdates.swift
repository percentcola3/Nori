import Foundation

/// Version checks are advisory; they never install updates.
enum L10nSoftwareUpdateTables {
    private static let keys = ["software.updates.check","software.updates.checking","software.updates.available","software.updates.current","software.updates.unsupported","software.updates.unsupportedHint","software.updates.failed","software.tools.readOnly"]
    private static let translations: [AppLanguage: [String]] = [
        .en: [
            "Check versions",
            "Checking…",
            "New version %@",
            "Up to date",
            "Source unsupported",
            "No reliable update source or comparable version is available. Check in the original app or its package manager.",
            "Check failed",
            "Externally managed"
        ],
        .zhHans: [
            "检测新版本",
            "检测中…",
            "新版本 %@",
            "暂无更新",
            "此来源暂不支持",
            "无法确定可靠的更新来源或比较版本，请在原应用或对应包管理器中检查更新。",
            "检测失败",
            "外部管理"
        ],
        .zhHant: [
            "檢查新版本",
            "檢查中…",
            "新版本 %@",
            "暫無更新",
            "此來源暫不支援",
            "無法確認可靠的更新來源或比較版本，請在原應用程式或對應套件管理員中檢查更新。",
            "檢查失敗",
            "外部管理"
        ],
        .ja: [
            "新バージョンを確認",
            "確認中…",
            "新バージョン %@",
            "更新なし",
            "未対応の配布元",
            "信頼できる更新元または比較可能なバージョンを確認できません。元のアプリまたはパッケージマネージャーで確認してください。",
            "確認失敗",
            "外部で管理"
        ],
        .ko: [
            "새 버전 확인",
            "확인 중…",
            "새 버전 %@",
            "업데이트 없음",
            "지원되지 않는 출처",
            "신뢰할 수 있는 업데이트 출처나 비교 가능한 버전을 확인할 수 없습니다. 원래 앱이나 패키지 관리자에서 확인하세요.",
            "확인 실패",
            "외부에서 관리"
        ],
        .de: [
            "Versionen prüfen",
            "Wird geprüft…",
            "Neue Version %@",
            "Keine Updates",
            "Quelle nicht unterstützt",
            "Keine zuverlässige Updatequelle oder vergleichbare Version verfügbar. Prüfe in der ursprünglichen App oder im Paketmanager.",
            "Prüfung fehlgeschlagen",
            "Extern verwaltet"
        ],
        .fr: [
            "Vérifier les versions",
            "Vérification…",
            "Nouvelle version %@",
            "À jour",
            "Source non prise en charge",
            "Aucune source de mise à jour fiable ou version comparable disponible. Vérifiez dans l’application ou son gestionnaire de paquets.",
            "Échec de vérification",
            "Gestion externe"
        ],
        .es: [
            "Comprobar versiones",
            "Comprobando…",
            "Nueva versión %@",
            "Sin actualizaciones",
            "Origen no compatible",
            "No hay un origen fiable de actualizaciones ni una versión comparable. Comprueba en la app original o en su gestor de paquetes.",
            "Error al comprobar",
            "Gestión externa"
        ],
        .pt: [
            "Verificar versões",
            "Verificando…",
            "Nova versão %@",
            "Sem atualizações",
            "Origem não compatível",
            "Não há uma origem confiável de atualizações ou uma versão comparável. Verifique no app original ou no gerenciador de pacotes.",
            "Falha na verificação",
            "Gerenciado externamente"
        ],
        .it: [
            "Controlla versioni",
            "Verifica…",
            "Nuova versione %@",
            "Nessun aggiornamento",
            "Origine non supportata",
            "Non è disponibile un’origine affidabile o una versione confrontabile. Controlla nell’app originale o nel gestore dei pacchetti.",
            "Verifica non riuscita",
            "Gestione esterna"
        ],
        .ru: [
            "Проверить версии",
            "Проверка…",
            "Новая версия %@",
            "Нет обновлений",
            "Источник не поддерживается",
            "Нет надёжного источника обновлений или сопоставимой версии. Проверьте в исходном приложении или менеджере пакетов.",
            "Ошибка проверки",
            "Внешнее управление"
        ],
        .tr: [
            "Sürümleri denetle",
            "Denetleniyor…",
            "Yeni sürüm %@",
            "Güncelleme yok",
            "Kaynak desteklenmiyor",
            "Güvenilir bir güncelleme kaynağı veya karşılaştırılabilir sürüm bulunamadı. Asıl uygulamadan veya paket yöneticisinden kontrol edin.",
            "Denetim başarısız",
            "Harici yönetim"
        ]
    ]
private static let installKeys = ["software.install.action","software.install.working","software.install.failed","software.install.closeTitle","software.install.closeMessage","software.install.closeAction","software.install.runtimeUnknown","software.install.closeFailed","software.install.changed","software.install.managerUnavailable","software.install.commandFailed","software.install.notVerified","software.install.openFailed","software.install.external"]
    private static let installTranslations: [AppLanguage: [String]] = [
        .en: [
            "Update",
            "Updating…",
            "Could not update %@",
            "Close %@ to update?",
            "%@ is running. Save your work first. Continuing will close it and its related processes, forcibly if needed, then update through its installation channel.",
            "Close and update",
            "Running processes could not be reliably checked. Try again.",
            "Some related processes could not be safely closed. Save your work, quit them and retry.",
            "The installation changed. Scan and check versions again.",
            "The package manager for this installation is unavailable.",
            "The update command did not complete. Check the log and retry.",
            "The requested new version could not be verified. Check versions again.",
            "The official update interface could not be opened.",
            "Complete in official updater"
        ],
        .zhHans: [
            "更新",
            "更新中…",
            "%@ 更新未完成",
            "关闭 %@ 后更新？",
            "%@ 正在运行。请先保存工作。继续将关闭它及相关进程（必要时强制结束），再通过对应渠道更新。",
            "关闭并更新",
            "无法可靠确认进程状态，请稍后重试。",
            "部分相关进程无法安全关闭，请保存工作并退出这些进程后重试。",
            "安装内容已变化，请重新扫描并检测新版本。",
            "此安装所需的包管理器不可用。",
            "更新命令未完成，请查看日志后重试。",
            "尚未确认已安装所需的新版本，请重新检测。",
            "无法打开官方更新界面。",
            "请在官方界面完成更新"
        ],
        .zhHant: [
            "更新",
            "更新中…",
            "%@ 更新未完成",
            "關閉 %@ 後更新？",
            "%@ 正在執行。請先儲存工作。繼續將關閉它與相關程序（必要時強制結束），再透過對應管道更新。",
            "關閉並更新",
            "無法可靠確認程序狀態，請稍後重試。",
            "部分相關程序無法安全關閉，請儲存工作並結束程序後重試。",
            "安裝內容已變更，請重新掃描及檢查新版本。",
            "此安裝所需的套件管理員無法使用。",
            "更新命令未完成，請查看記錄後重試。",
            "尚未確認所需的新版本已安裝，請重新檢查。",
            "無法開啟官方更新介面。",
            "請在官方介面完成更新"
        ],
        .ja: [
            "更新",
            "更新中…",
            "%@ を更新できませんでした",
            "%@ を終了して更新しますか？",
            "%@ は実行中です。先に作業を保存してください。続行すると関連プロセスも含めて終了し、必要な場合は強制終了してから、インストール元を通じて更新します。",
            "終了して更新",
            "プロセスの状態を確実に確認できません。再試行してください。",
            "一部の関連プロセスを安全に終了できません。作業を保存して終了し、再試行してください。",
            "インストールが変更されました。再スキャンしてバージョンを確認してください。",
            "このインストールに必要なパッケージマネージャーを利用できません。",
            "更新コマンドが完了しませんでした。ログを確認して再試行してください。",
            "必要な新バージョンのインストールを確認できません。再確認してください。",
            "公式の更新画面を開けませんでした。",
            "公式の更新画面で完了してください"
        ],
        .ko: [
            "업데이트",
            "업데이트 중…",
            "%@ 업데이트 미완료",
            "%@을(를) 닫고 업데이트할까요?",
            "%@이(가) 실행 중입니다. 먼저 작업을 저장하세요. 계속하면 관련 프로세스도 닫고 필요 시 강제 종료한 후 설치 경로를 통해 업데이트합니다.",
            "닫고 업데이트",
            "프로세스 상태를 확인할 수 없습니다. 다시 시도하세요.",
            "일부 관련 프로세스를 안전하게 닫지 못했습니다. 작업을 저장하고 종료한 후 다시 시도하세요.",
            "설치 내용이 변경되었습니다. 다시 스캔하고 버전을 확인하세요.",
            "이 설치에 필요한 패키지 관리자를 사용할 수 없습니다.",
            "업데이트 명령이 완료되지 않았습니다. 로그를 확인한 후 다시 시도하세요.",
            "필요한 새 버전 설치를 확인하지 못했습니다. 다시 확인하세요.",
            "공식 업데이트 화면을 열지 못했습니다.",
            "공식 업데이트 화면에서 완료하세요"
        ],
        .de: [
            "Aktualisieren",
            "Aktualisierung…",
            "%@ konnte nicht aktualisiert werden",
            "%@ zum Aktualisieren schließen?",
            "%@ läuft. Speichere zuerst deine Arbeit. Beim Fortfahren werden auch zugehörige Prozesse beendet, bei Bedarf sofort, und die Software über ihren Installationskanal aktualisiert.",
            "Schließen und aktualisieren",
            "Der Prozessstatus konnte nicht zuverlässig geprüft werden. Versuche es erneut.",
            "Einige Prozesse konnten nicht sicher beendet werden. Speichere deine Arbeit, beende sie und versuche es erneut.",
            "Die Installation hat sich geändert. Scanne und prüfe Versionen erneut.",
            "Der Paketmanager dieser Installation ist nicht verfügbar.",
            "Der Updatebefehl wurde nicht abgeschlossen. Prüfe das Protokoll und versuche es erneut.",
            "Die angeforderte neue Version konnte nicht bestätigt werden. Prüfe erneut.",
            "Die offizielle Updateoberfläche konnte nicht geöffnet werden.",
            "Im offiziellen Updater abschließen"
        ],
        .fr: [
            "Mettre à jour",
            "Mise à jour…",
            "Mise à jour de %@ incomplète",
            "Fermer %@ pour mettre à jour ?",
            "%@ est en cours d’exécution. Enregistrez votre travail. Continuer fermera ses processus associés, de force si nécessaire, puis mettra à jour via son canal d’installation.",
            "Fermer et mettre à jour",
            "L’état des processus n’a pas pu être vérifié. Réessayez.",
            "Certains processus n’ont pas pu être fermés. Enregistrez votre travail, quittez-les, puis réessayez.",
            "L’installation a changé. Relancez l’analyse et la vérification des versions.",
            "Le gestionnaire de paquets de cette installation n’est pas disponible.",
            "La commande de mise à jour n’a pas abouti. Consultez le journal, puis réessayez.",
            "La nouvelle version demandée n’a pas pu être vérifiée. Vérifiez à nouveau.",
            "L’interface de mise à jour officielle n’a pas pu être ouverte.",
            "Terminez dans l’interface officielle"
        ],
        .es: [
            "Actualizar",
            "Actualizando…",
            "No se completó la actualización de %@",
            "¿Cerrar %@ para actualizar?",
            "%@ está en ejecución. Guarda tu trabajo. Continuar cerrará también sus procesos relacionados, por la fuerza si es necesario, y actualizará mediante su canal de instalación.",
            "Cerrar y actualizar",
            "No se pudo comprobar el estado de los procesos. Vuelve a intentarlo.",
            "No se pudieron cerrar algunos procesos de forma segura. Guarda tu trabajo, ciérralos e inténtalo de nuevo.",
            "La instalación ha cambiado. Vuelve a analizar y comprobar las versiones.",
            "El gestor de paquetes de esta instalación no está disponible.",
            "La orden de actualización no se completó. Revisa el registro e inténtalo de nuevo.",
            "No se pudo verificar la nueva versión solicitada. Vuelve a comprobarlo.",
            "No se pudo abrir la interfaz oficial de actualización.",
            "Completa en la interfaz oficial"
        ],
        .pt: [
            "Atualizar",
            "Atualizando…",
            "Atualização de %@ incompleta",
            "Fechar %@ para atualizar?",
            "%@ está em execução. Salve seu trabalho. Continuar encerrará também os processos relacionados, à força se necessário, e atualizará pelo canal de instalação.",
            "Fechar e atualizar",
            "Não foi possível verificar o estado dos processos. Tente novamente.",
            "Alguns processos não puderam ser encerrados com segurança. Salve seu trabalho, encerre-os e tente novamente.",
            "A instalação mudou. Analise e verifique as versões novamente.",
            "O gerenciador de pacotes desta instalação está indisponível.",
            "O comando de atualização não foi concluído. Confira o registro e tente novamente.",
            "A nova versão solicitada não pôde ser verificada. Verifique novamente.",
            "Não foi possível abrir a interface oficial de atualização.",
            "Conclua na interface oficial"
        ],
        .it: [
            "Aggiorna",
            "Aggiornamento…",
            "Aggiornamento di %@ incompleto",
            "Chiudere %@ per aggiornare?",
            "%@ è in esecuzione. Salva il lavoro. Continuando saranno chiusi anche i processi associati, forzatamente se necessario, poi l’app sarà aggiornata tramite il suo canale di installazione.",
            "Chiudi e aggiorna",
            "Impossibile verificare lo stato dei processi. Riprova.",
            "Alcuni processi non possono essere chiusi in sicurezza. Salva il lavoro, chiudili e riprova.",
            "L’installazione è cambiata. Ripeti la scansione e il controllo delle versioni.",
            "Il gestore dei pacchetti di questa installazione non è disponibile.",
            "Il comando di aggiornamento non è stato completato. Controlla il registro e riprova.",
            "Impossibile verificare la nuova versione richiesta. Controlla di nuovo.",
            "Impossibile aprire l’interfaccia ufficiale di aggiornamento.",
            "Completa nell’interfaccia ufficiale"
        ],
        .ru: [
            "Обновить",
            "Обновление…",
            "Обновление %@ не завершено",
            "Закрыть %@ для обновления?",
            "%@ работает. Сохраните работу. Продолжение завершит связанные процессы, при необходимости принудительно, и обновит программу через её канал установки.",
            "Закрыть и обновить",
            "Не удалось проверить состояние процессов. Повторите попытку.",
            "Некоторые процессы нельзя безопасно завершить. Сохраните работу, завершите их и повторите попытку.",
            "Установка изменилась. Сканируйте и проверьте версии снова.",
            "Менеджер пакетов этой установки недоступен.",
            "Команда обновления не завершена. Проверьте журнал и повторите попытку.",
            "Не удалось подтвердить установку запрошенной версии. Проверьте снова.",
            "Не удалось открыть официальный интерфейс обновления.",
            "Завершите в официальном интерфейсе"
        ],
        .tr: [
            "Güncelle",
            "Güncelleniyor…",
            "%@ güncellemesi tamamlanmadı",
            "%@ güncellemek için kapatılsın mı?",
            "%@ çalışıyor. Önce çalışmanızı kaydedin. Devam edilirse ilgili işlemler de kapatılır, gerekirse zorla sonlandırılır ve kurulum kanalı üzerinden güncellenir.",
            "Kapat ve güncelle",
            "İşlem durumu güvenilir şekilde denetlenemedi. Tekrar deneyin.",
            "Bazı işlemler güvenli şekilde kapatılamadı. Çalışmanızı kaydedin, işlemleri kapatın ve tekrar deneyin.",
            "Kurulum değişti. Yeniden tarayıp sürümleri denetleyin.",
            "Bu kurulumun paket yöneticisi kullanılamıyor.",
            "Güncelleme komutu tamamlanmadı. Günlüğü kontrol edip tekrar deneyin.",
            "İstenen yeni sürüm doğrulanamadı. Tekrar denetleyin.",
            "Resmî güncelleme arayüzü açılamadı.",
            "Resmî arayüzde tamamlayın"
        ]
    ]

    static func table(for language: AppLanguage) -> [String: String] {
        guard let values = translations[language] else { return [:] }
        precondition(values.count == keys.count)
        let install = installTranslations[language] ?? []
        precondition(install.count == installKeys.count)
        return Dictionary(uniqueKeysWithValues: zip(keys, values))
            .merging(Dictionary(uniqueKeysWithValues: zip(installKeys, install))) { _, value in value }
    }
}
