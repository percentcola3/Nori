import Foundation

/// Task feedback is fully translated; failure dialogs never fall back to English.
enum L10nTaskFeedbackTables {
    private static let keys = [
        "task.failure.title", "task.failure.message", "task.failure.partial",
        "task.closeApps.title", "task.closeApps.message", "task.closeApps.changed",
        "task.closeApps.check", "task.details", "task.dismiss", "task.cancel",
        "task.failure.unknown", "task.failure.runtimeUnknown", "task.failure.skipped",
        "task.reason.runningApps", "task.reason.runtimeUnknown", "task.reason.changed",
        "task.reason.protected", "task.reason.open", "task.reason.path", "task.reason.absent",
        "task.reason.config", "task.reason.backup", "task.reason.remove", "task.reason.cli",
        "task.reason.validation", "task.reason.managerUnavailable", "task.reason.status"
    ]

    private static let translations: [AppLanguage: [String]] = [
        .en: [
            "Task could not be completed",
            "The task did not complete. Review the reason below and try again.",
            "Some items were not processed. Review the reason before retrying.",
            "Close applications to continue",
            "Save your work and fully quit these applications or related CLI processes before continuing. No selected items have been cleaned.",
            "These applications are still running. Fully quit them, then check again.",
            "Check again and continue", "Details", "OK", "Cancel",
            "No additional details are available. Please try again.",
            "Running applications could not be checked. No items were cleaned. Please try again.",
            "Some selected items were kept because their state changed or cleanup could not be verified. Scan again before retrying.",
            "Related applications or CLI processes are still running. Quit them before trying again.",
            "The running-process or open-file state could not be verified. Close the related applications, then try again.",
            "The item changed after scanning. Scan again before retrying.",
            "The item is protected by cleanup rules or your whitelist.",
            "A process is using this item. Close the related application or CLI process before retrying.",
            "The item path is unsafe or outside the allowed cleanup locations.",
            "The item is already absent.",
            "The configuration could not be read or safely updated. Review it, then scan again.",
            "The configuration changed or its backup could not be created. Scan again and check available storage and folder permissions.",
            "The item could not be removed. Check its permissions and try again.",
            "The CLI uninstall did not complete. Check the installation and its package manager, then scan again.",
            "Cleanup could not be verified. Scan again before retrying.",
            "The package manager for this CLI installation is unavailable.",
            "The package manager exited with status %@."
        ],
        .zhHans: [
            "任务未能完成",
            "任务未能完成。请查看下方原因后重试。",
            "部分项目未处理。请查看原因后重试。",
            "退出应用后继续",
            "请先保存工作，并完全退出以下应用或相关 CLI 进程，再继续操作。所选项目尚未清理。",
            "这些应用仍在运行。请完全退出后重新检查。",
            "重新检查并继续", "详情", "好", "取消",
            "暂无更多详情，请重试。",
            "无法检查正在运行的应用，尚未清理任何项目。请重试。",
            "部分所选项目因状态变化或无法验证清理条件而保留。请重新扫描后重试。",
            "相关应用或 CLI 进程仍在运行。请完全退出后重试。",
            "无法验证进程或文件占用状态。请退出相关应用后重试。",
            "项目在扫描后发生变化。请重新扫描后重试。",
            "此项目受清理规则或白名单保护。",
            "此项目正在被进程使用。请退出相关应用或 CLI 进程后重试。",
            "项目路径不安全，或不在允许清理的位置内。",
            "此项目已不存在。",
            "无法读取或安全更新配置。请检查配置后重新扫描。",
            "配置发生变化或无法创建备份。请重新扫描，并检查可用空间和文件夹权限。",
            "无法移除此项目。请检查权限后重试。",
            "CLI 卸载未完成。请检查安装和包管理器后重新扫描。",
            "无法验证清理条件。请重新扫描后重试。",
            "此 CLI 安装所需的包管理器不可用。",
            "包管理器退出，状态码为 %@。"
        ],
        .zhHant: [
            "工作未能完成",
            "工作未能完成。請查看下方原因後重試。",
            "部分項目未處理。請查看原因後重試。",
            "結束應用程式後繼續",
            "請先儲存工作，並完全結束以下應用程式或相關 CLI 程序，再繼續操作。所選項目尚未清理。",
            "這些應用程式仍在執行。請完全結束後重新檢查。",
            "重新檢查並繼續", "詳細資訊", "好", "取消",
            "暫無更多詳細資訊，請重試。",
            "無法檢查正在執行的應用程式，尚未清理任何項目。請重試。",
            "部分所選項目因狀態變更或無法驗證清理條件而保留。請重新掃描後重試。",
            "相關應用程式或 CLI 程序仍在執行。請完全結束後重試。",
            "無法驗證程序或檔案使用狀態。請結束相關應用程式後重試。",
            "項目在掃描後發生變更。請重新掃描後重試。",
            "此項目受清理規則或白名單保護。",
            "此項目正在被程序使用。請結束相關應用程式或 CLI 程序後重試。",
            "項目路徑不安全，或不在允許清理的位置內。",
            "此項目已不存在。",
            "無法讀取或安全更新設定。請檢查設定後重新掃描。",
            "設定發生變更或無法建立備份。請重新掃描，並檢查可用空間和檔案夾權限。",
            "無法移除此項目。請檢查權限後重試。",
            "CLI 解除安裝未完成。請檢查安裝和套件管理器後重新掃描。",
            "無法驗證清理條件。請重新掃描後重試。",
            "此 CLI 安裝所需的套件管理器無法使用。",
            "套件管理器結束，狀態碼為 %@。"
        ],
        .ja: [
            "タスクを完了できませんでした",
            "タスクを完了できませんでした。以下の理由を確認して、もう一度お試しください。",
            "一部の項目は処理されませんでした。理由を確認してから再試行してください。",
            "アプリを終了して続行",
            "作業を保存し、以下のアプリまたは関連する CLI プロセスを完全に終了してから続行してください。選択した項目はまだクリーンアップされていません。",
            "これらのアプリはまだ実行中です。完全に終了してから再確認してください。",
            "再確認して続行", "詳細", "OK", "キャンセル",
            "追加の詳細はありません。もう一度お試しください。",
            "実行中のアプリを確認できませんでした。項目はクリーンアップされていません。もう一度お試しください。",
            "状態が変わったか、クリーンアップ条件を確認できなかったため、一部の選択項目を保持しました。再スキャンしてから再試行してください。",
            "関連するアプリまたは CLI プロセスが実行中です。終了してから再試行してください。",
            "プロセスやファイルの使用状況を確認できませんでした。関連するアプリを終了してから再試行してください。",
            "スキャン後に項目が変更されました。再スキャンしてから再試行してください。",
            "この項目はクリーンアップ規則またはホワイトリストで保護されています。",
            "この項目はプロセスが使用中です。関連するアプリまたは CLI プロセスを終了してから再試行してください。",
            "項目のパスが安全ではないか、許可されたクリーンアップ場所の範囲外です。",
            "この項目はすでに存在しません。",
            "設定を読み取るか安全に更新できませんでした。設定を確認してから再スキャンしてください。",
            "設定が変更されたか、バックアップを作成できませんでした。再スキャンし、空き容量とフォルダの権限を確認してください。",
            "この項目を削除できませんでした。権限を確認して再試行してください。",
            "CLI のアンインストールが完了しませんでした。インストールとパッケージマネージャーを確認してから再スキャンしてください。",
            "クリーンアップ条件を確認できませんでした。再スキャンしてから再試行してください。",
            "この CLI のパッケージマネージャーを利用できません。",
            "パッケージマネージャーが終了しました。終了コード: %@。"
        ],
        .ko: [
            "작업을 완료하지 못했습니다",
            "작업이 완료되지 않았습니다. 아래 이유를 확인한 후 다시 시도하세요.",
            "일부 항목이 처리되지 않았습니다. 이유를 확인한 후 다시 시도하세요.",
            "앱을 종료한 후 계속",
            "작업을 저장하고 다음 앱 또는 관련 CLI 프로세스를 완전히 종료한 후 계속하세요. 선택한 항목은 아직 정리되지 않았습니다.",
            "이 앱들이 아직 실행 중입니다. 완전히 종료한 후 다시 확인하세요.",
            "다시 확인하고 계속", "세부 정보", "확인", "취소",
            "추가 세부 정보가 없습니다. 다시 시도하세요.",
            "실행 중인 앱을 확인하지 못했습니다. 정리된 항목은 없습니다. 다시 시도하세요.",
            "상태가 변경되었거나 정리 조건을 확인할 수 없어 일부 선택 항목을 유지했습니다. 다시 스캔한 후 시도하세요.",
            "관련 앱 또는 CLI 프로세스가 아직 실행 중입니다. 종료한 후 다시 시도하세요.",
            "프로세스 또는 파일 사용 상태를 확인하지 못했습니다. 관련 앱을 종료한 후 다시 시도하세요.",
            "스캔 후 항목이 변경되었습니다. 다시 스캔한 후 시도하세요.",
            "이 항목은 정리 규칙 또는 허용 목록으로 보호됩니다.",
            "프로세스가 이 항목을 사용 중입니다. 관련 앱 또는 CLI 프로세스를 종료한 후 다시 시도하세요.",
            "항목 경로가 안전하지 않거나 허용된 정리 위치 밖에 있습니다.",
            "이 항목은 이미 없습니다.",
            "설정을 읽거나 안전하게 업데이트하지 못했습니다. 설정을 확인한 후 다시 스캔하세요.",
            "설정이 변경되었거나 백업을 만들지 못했습니다. 다시 스캔하고 여유 공간과 폴더 권한을 확인하세요.",
            "이 항목을 제거하지 못했습니다. 권한을 확인한 후 다시 시도하세요.",
            "CLI 제거가 완료되지 않았습니다. 설치와 패키지 관리자를 확인한 후 다시 스캔하세요.",
            "정리 조건을 확인하지 못했습니다. 다시 스캔한 후 시도하세요.",
            "이 CLI 설치의 패키지 관리자를 사용할 수 없습니다.",
            "패키지 관리자가 상태 코드 %@로 종료되었습니다."
        ],
        .de: [
            "Aufgabe konnte nicht abgeschlossen werden",
            "Die Aufgabe wurde nicht abgeschlossen. Prüfe den folgenden Grund und versuche es erneut.",
            "Einige Elemente wurden nicht verarbeitet. Prüfe vor einem erneuten Versuch den Grund.",
            "Apps schließen, um fortzufahren",
            "Speichere deine Arbeit und beende diese Apps oder zugehörige CLI-Prozesse vollständig, bevor du fortfährst. Ausgewählte Elemente wurden noch nicht bereinigt.",
            "Diese Apps laufen noch. Beende sie vollständig und prüfe erneut.",
            "Erneut prüfen und fortfahren", "Details", "OK", "Abbrechen",
            "Keine weiteren Details verfügbar. Versuche es erneut.",
            "Laufende Apps konnten nicht geprüft werden. Es wurde nichts bereinigt. Versuche es erneut.",
            "Einige ausgewählte Elemente wurden behalten, weil sich ihr Zustand geändert hat oder die Bereinigung nicht geprüft werden konnte. Scanne vor dem nächsten Versuch erneut.",
            "Zugehörige Apps oder CLI-Prozesse laufen noch. Beende sie vor einem erneuten Versuch.",
            "Der Prozessstatus oder die Dateinutzung konnte nicht geprüft werden. Schließe die zugehörigen Apps und versuche es erneut.",
            "Das Element wurde nach dem Scan geändert. Scanne vor dem nächsten Versuch erneut.",
            "Das Element ist durch Bereinigungsregeln oder deine Ausnahmeliste geschützt.",
            "Ein Prozess verwendet dieses Element. Beende die zugehörige App oder den CLI-Prozess vor einem erneuten Versuch.",
            "Der Pfad ist unsicher oder liegt außerhalb der erlaubten Bereinigungsorte.",
            "Das Element ist bereits nicht mehr vorhanden.",
            "Die Konfiguration konnte nicht gelesen oder sicher aktualisiert werden. Prüfe sie und scanne erneut.",
            "Die Konfiguration wurde geändert oder konnte nicht gesichert werden. Scanne erneut und prüfe freien Speicherplatz und Ordnerberechtigungen.",
            "Das Element konnte nicht entfernt werden. Prüfe die Berechtigungen und versuche es erneut.",
            "Die CLI-Deinstallation wurde nicht abgeschlossen. Prüfe Installation und Paketmanager und scanne erneut.",
            "Die Bereinigung konnte nicht geprüft werden. Scanne vor dem nächsten Versuch erneut.",
            "Der Paketmanager dieser CLI-Installation ist nicht verfügbar.",
            "Der Paketmanager wurde mit Status %@ beendet."
        ],
        .fr: [
            "La tâche n’a pas pu être terminée",
            "La tâche n’a pas abouti. Consultez la raison ci-dessous, puis réessayez.",
            "Certains éléments n’ont pas été traités. Consultez la raison avant de réessayer.",
            "Quittez les applications pour continuer",
            "Enregistrez votre travail et quittez complètement ces applications ou les processus CLI associés avant de continuer. Aucun élément sélectionné n’a été nettoyé.",
            "Ces applications sont toujours en cours d’exécution. Quittez-les complètement, puis vérifiez à nouveau.",
            "Vérifier à nouveau et continuer", "Détails", "OK", "Annuler",
            "Aucun détail supplémentaire n’est disponible. Réessayez.",
            "Impossible de vérifier les applications en cours d’exécution. Aucun élément n’a été nettoyé. Réessayez.",
            "Certains éléments sélectionnés ont été conservés car leur état a changé ou le nettoyage n’a pas pu être vérifié. Relancez l’analyse avant de réessayer.",
            "Des applications ou processus CLI associés sont toujours en cours d’exécution. Quittez-les avant de réessayer.",
            "Impossible de vérifier l’état des processus ou l’utilisation des fichiers. Quittez les applications associées, puis réessayez.",
            "L’élément a changé après l’analyse. Relancez l’analyse avant de réessayer.",
            "L’élément est protégé par les règles de nettoyage ou votre liste d’exceptions.",
            "Un processus utilise cet élément. Quittez l’application ou le processus CLI associé avant de réessayer.",
            "Le chemin de l’élément est dangereux ou se trouve hors des emplacements autorisés pour le nettoyage.",
            "L’élément n’existe déjà plus.",
            "Impossible de lire ou de mettre à jour la configuration en toute sécurité. Vérifiez-la, puis relancez l’analyse.",
            "La configuration a changé ou sa sauvegarde n’a pas pu être créée. Relancez l’analyse et vérifiez l’espace disponible et les autorisations du dossier.",
            "Impossible de supprimer cet élément. Vérifiez ses autorisations, puis réessayez.",
            "La désinstallation de la CLI n’a pas abouti. Vérifiez l’installation et son gestionnaire de paquets, puis relancez l’analyse.",
            "Impossible de vérifier le nettoyage. Relancez l’analyse avant de réessayer.",
            "Le gestionnaire de paquets de cette installation CLI est indisponible.",
            "Le gestionnaire de paquets s’est arrêté avec le code %@."
        ],
        .es: [
            "No se pudo completar la tarea",
            "La tarea no se completó. Revisa el motivo a continuación e inténtalo de nuevo.",
            "Algunos elementos no se procesaron. Revisa el motivo antes de volver a intentarlo.",
            "Cierra las aplicaciones para continuar",
            "Guarda tu trabajo y cierra por completo estas aplicaciones o los procesos CLI relacionados antes de continuar. No se ha limpiado ningún elemento seleccionado.",
            "Estas aplicaciones siguen ejecutándose. Ciérralas por completo y vuelve a comprobarlo.",
            "Comprobar de nuevo y continuar", "Detalles", "Aceptar", "Cancelar",
            "No hay más detalles disponibles. Inténtalo de nuevo.",
            "No se pudieron comprobar las aplicaciones en ejecución. No se ha limpiado ningún elemento. Inténtalo de nuevo.",
            "Se conservaron algunos elementos seleccionados porque su estado cambió o no se pudo verificar la limpieza. Vuelve a analizar antes de reintentarlo.",
            "Las aplicaciones o los procesos CLI relacionados siguen ejecutándose. Ciérralos antes de volver a intentarlo.",
            "No se pudo verificar el estado de los procesos o el uso de archivos. Cierra las aplicaciones relacionadas e inténtalo de nuevo.",
            "El elemento cambió después del análisis. Vuelve a analizar antes de reintentarlo.",
            "El elemento está protegido por las reglas de limpieza o tu lista de excepciones.",
            "Un proceso está usando este elemento. Cierra la aplicación o el proceso CLI relacionado antes de reintentarlo.",
            "La ruta no es segura o está fuera de las ubicaciones permitidas para la limpieza.",
            "El elemento ya no existe.",
            "No se pudo leer o actualizar la configuración de forma segura. Revísala y vuelve a analizar.",
            "La configuración cambió o no se pudo crear su copia de seguridad. Vuelve a analizar y comprueba el espacio disponible y los permisos de la carpeta.",
            "No se pudo eliminar este elemento. Comprueba sus permisos e inténtalo de nuevo.",
            "La desinstalación de la CLI no se completó. Comprueba la instalación y el gestor de paquetes y vuelve a analizar.",
            "No se pudo verificar la limpieza. Vuelve a analizar antes de reintentarlo.",
            "El gestor de paquetes de esta instalación CLI no está disponible.",
            "El gestor de paquetes terminó con el código %@."
        ],
        .pt: [
            "Não foi possível concluir a tarefa",
            "A tarefa não foi concluída. Confira o motivo abaixo e tente novamente.",
            "Alguns itens não foram processados. Confira o motivo antes de tentar novamente.",
            "Feche os aplicativos para continuar",
            "Salve seu trabalho e encerre completamente estes aplicativos ou processos CLI relacionados antes de continuar. Nenhum item selecionado foi limpo.",
            "Estes aplicativos ainda estão em execução. Encerre-os completamente e verifique novamente.",
            "Verificar novamente e continuar", "Detalhes", "OK", "Cancelar",
            "Não há mais detalhes disponíveis. Tente novamente.",
            "Não foi possível verificar os aplicativos em execução. Nenhum item foi limpo. Tente novamente.",
            "Alguns itens selecionados foram mantidos porque seu estado mudou ou a limpeza não pôde ser verificada. Analise novamente antes de tentar.",
            "Aplicativos ou processos CLI relacionados ainda estão em execução. Encerre-os antes de tentar novamente.",
            "Não foi possível verificar o estado dos processos ou o uso dos arquivos. Feche os aplicativos relacionados e tente novamente.",
            "O item mudou após a análise. Analise novamente antes de tentar.",
            "O item está protegido pelas regras de limpeza ou pela sua lista de exceções.",
            "Um processo está usando este item. Encerre o aplicativo ou processo CLI relacionado antes de tentar novamente.",
            "O caminho não é seguro ou está fora dos locais permitidos para limpeza.",
            "O item já não existe.",
            "Não foi possível ler ou atualizar a configuração com segurança. Confira-a e analise novamente.",
            "A configuração mudou ou seu backup não pôde ser criado. Analise novamente e confira o espaço disponível e as permissões da pasta.",
            "Não foi possível remover este item. Confira suas permissões e tente novamente.",
            "A desinstalação da CLI não foi concluída. Confira a instalação e o gerenciador de pacotes e analise novamente.",
            "Não foi possível verificar a limpeza. Analise novamente antes de tentar.",
            "O gerenciador de pacotes desta instalação CLI não está disponível.",
            "O gerenciador de pacotes encerrou com o código %@."
        ],
        .it: [
            "Impossibile completare l’attività",
            "L’attività non è stata completata. Controlla il motivo qui sotto e riprova.",
            "Alcuni elementi non sono stati elaborati. Controlla il motivo prima di riprovare.",
            "Chiudi le app per continuare",
            "Salva il lavoro e chiudi completamente queste app o i processi CLI associati prima di continuare. Nessun elemento selezionato è stato pulito.",
            "Queste app sono ancora in esecuzione. Chiudile completamente, poi controlla di nuovo.",
            "Controlla di nuovo e continua", "Dettagli", "OK", "Annulla",
            "Non sono disponibili ulteriori dettagli. Riprova.",
            "Impossibile controllare le app in esecuzione. Nessun elemento è stato pulito. Riprova.",
            "Alcuni elementi selezionati sono stati mantenuti perché il loro stato è cambiato o non è stato possibile verificare la pulizia. Ripeti la scansione prima di riprovare.",
            "Le app o i processi CLI associati sono ancora in esecuzione. Chiudili prima di riprovare.",
            "Impossibile verificare lo stato dei processi o l’uso dei file. Chiudi le app associate e riprova.",
            "L’elemento è cambiato dopo la scansione. Ripeti la scansione prima di riprovare.",
            "L’elemento è protetto dalle regole di pulizia o dalla tua lista di eccezioni.",
            "Un processo sta usando questo elemento. Chiudi l’app o il processo CLI associato prima di riprovare.",
            "Il percorso non è sicuro o non rientra nelle posizioni consentite per la pulizia.",
            "L’elemento non esiste più.",
            "Impossibile leggere o aggiornare la configurazione in modo sicuro. Controllala, poi ripeti la scansione.",
            "La configurazione è cambiata o non è stato possibile crearne il backup. Ripeti la scansione e controlla lo spazio disponibile e i permessi della cartella.",
            "Impossibile rimuovere questo elemento. Controlla i permessi e riprova.",
            "La disinstallazione della CLI non è stata completata. Controlla l’installazione e il gestore di pacchetti, poi ripeti la scansione.",
            "Impossibile verificare la pulizia. Ripeti la scansione prima di riprovare.",
            "Il gestore di pacchetti di questa installazione CLI non è disponibile.",
            "Il gestore di pacchetti è terminato con il codice %@."
        ],
        .ru: [
            "Не удалось завершить задачу",
            "Задача не завершена. Ознакомьтесь с причиной ниже и повторите попытку.",
            "Некоторые объекты не обработаны. Ознакомьтесь с причиной перед повторной попыткой.",
            "Закройте приложения для продолжения",
            "Сохраните работу и полностью завершите эти приложения или связанные процессы CLI. Выбранные объекты ещё не очищены.",
            "Эти приложения ещё работают. Полностью завершите их и проверьте снова.",
            "Проверить снова и продолжить", "Подробности", "ОК", "Отмена",
            "Дополнительные сведения недоступны. Повторите попытку.",
            "Не удалось проверить работающие приложения. Ничего не очищено. Повторите попытку.",
            "Некоторые выбранные объекты сохранены: их состояние изменилось или условия очистки не удалось проверить. Сканируйте снова перед повторной попыткой.",
            "Связанные приложения или процессы CLI ещё работают. Завершите их перед повторной попыткой.",
            "Не удалось проверить процессы или использование файлов. Закройте связанные приложения и повторите попытку.",
            "Объект изменился после сканирования. Сканируйте снова перед повторной попыткой.",
            "Объект защищён правилами очистки или вашим списком исключений.",
            "Процесс использует этот объект. Завершите связанное приложение или процесс CLI перед повторной попыткой.",
            "Путь объекта небезопасен или находится вне разрешённых мест очистки.",
            "Объект уже отсутствует.",
            "Не удалось прочитать или безопасно обновить конфигурацию. Проверьте её и сканируйте снова.",
            "Конфигурация изменилась или её резервную копию не удалось создать. Сканируйте снова и проверьте свободное место и права доступа к папке.",
            "Не удалось удалить объект. Проверьте права доступа и повторите попытку.",
            "Удаление CLI не завершено. Проверьте установку и менеджер пакетов, затем сканируйте снова.",
            "Не удалось проверить условия очистки. Сканируйте снова перед повторной попыткой.",
            "Менеджер пакетов этой установки CLI недоступен.",
            "Менеджер пакетов завершился с кодом %@."
        ],
        .tr: [
            "Görev tamamlanamadı",
            "Görev tamamlanmadı. Aşağıdaki nedeni inceleyip tekrar deneyin.",
            "Bazı öğeler işlenmedi. Tekrar denemeden önce nedeni inceleyin.",
            "Devam etmek için uygulamaları kapatın",
            "Çalışmanızı kaydedin ve devam etmeden önce bu uygulamaları veya ilgili CLI işlemlerini tamamen kapatın. Seçilen hiçbir öğe temizlenmedi.",
            "Bu uygulamalar hâlâ çalışıyor. Tamamen kapatıp yeniden kontrol edin.",
            "Yeniden kontrol et ve devam et", "Ayrıntılar", "Tamam", "İptal",
            "Ek ayrıntı yok. Lütfen tekrar deneyin.",
            "Çalışan uygulamalar kontrol edilemedi. Hiçbir öğe temizlenmedi. Tekrar deneyin.",
            "Durumları değiştiği veya temizleme koşulları doğrulanamadığı için bazı seçili öğeler korundu. Tekrar denemeden önce yeniden tarayın.",
            "İlgili uygulamalar veya CLI işlemleri hâlâ çalışıyor. Tekrar denemeden önce kapatın.",
            "İşlem veya dosya kullanım durumu doğrulanamadı. İlgili uygulamaları kapatıp tekrar deneyin.",
            "Öğe taramadan sonra değişti. Tekrar denemeden önce yeniden tarayın.",
            "Öğe, temizleme kuralları veya izin listeniz tarafından korunuyor.",
            "Bir işlem bu öğeyi kullanıyor. Tekrar denemeden önce ilgili uygulamayı veya CLI işlemini kapatın.",
            "Öğe yolu güvenli değil veya izin verilen temizleme konumlarının dışında.",
            "Öğe zaten mevcut değil.",
            "Yapılandırma okunamadı veya güvenli şekilde güncellenemedi. Kontrol edip yeniden tarayın.",
            "Yapılandırma değişti veya yedeği oluşturulamadı. Yeniden tarayın, boş alanı ve klasör izinlerini kontrol edin.",
            "Öğe kaldırılamadı. İzinlerini kontrol edip tekrar deneyin.",
            "CLI kaldırma işlemi tamamlanmadı. Kurulumu ve paket yöneticisini kontrol edip yeniden tarayın.",
            "Temizleme koşulları doğrulanamadı. Tekrar denemeden önce yeniden tarayın.",
            "Bu CLI kurulumunun paket yöneticisi kullanılamıyor.",
            "Paket yöneticisi %@ durum koduyla sonlandı."
        ]
    ]

    static func table(for language: AppLanguage) -> [String: String] {
        guard let values = translations[language] else { return [:] }
        precondition(values.count == keys.count, "Task feedback translation count mismatch")
        let developerValues = developerTranslations[language] ?? []
        precondition(developerValues.count == developerKeys.count, "Developer task feedback translation count mismatch")
        let summaryValues = summaryTranslations[language] ?? []
        precondition(summaryValues.count == summaryKeys.count, "Task summary translation count mismatch")
        let remainingValues = remainingTranslations[language] ?? []
        precondition(remainingValues.count == remainingKeys.count, "Remaining task translation count mismatch")
        return Dictionary(uniqueKeysWithValues: zip(keys, values))
            .merging(Dictionary(uniqueKeysWithValues: zip(developerKeys, developerValues))) { _, value in value }
            .merging(Dictionary(uniqueKeysWithValues: zip(summaryKeys, summaryValues))) { _, value in value }
            .merging(Dictionary(uniqueKeysWithValues: zip(remainingKeys, remainingValues))) { _, value in value }
    }

    private static let developerKeys = [
        "task.reason.hostsUnavailable", "task.reason.hostsTooLarge", "task.reason.hostsInvalidLine",
        "task.reason.hostsProtected", "task.reason.hostsSave", "task.reason.testMode",
        "task.reason.configChanged", "task.reason.shellInvalidVariable", "task.reason.shellDynamicVariable",
        "task.reason.shellEncoding", "task.reason.shellTooLarge", "task.reason.shellSyntax",
        "task.reason.terminal"
    ]

    private static let developerTranslations: [AppLanguage: [String]] = [
        .en: [
            "The hosts file cannot be read safely. Check its type and permissions.",
            "The hosts file exceeds the 64 KB editor limit. Use an external editor.",
            "The hosts draft contains an invalid IP address or hostname. Review the indicated line before saving.",
            "Keep these system mappings: 127.0.0.1 localhost, ::1 localhost, and 255.255.255.255 broadcasthost.",
            "The hosts file could not be saved. Check administrator authorization. Your draft has been kept.",
            "System changes are disabled in test mode.",
            "The file changed outside Nori. Reload the current file before saving. Your draft has been kept.",
            "Variable names must start with a letter or underscore and contain only letters, digits, or underscores. Values cannot contain newlines.",
            "Edit dynamic or complex variable declarations in the full source file.",
            "Only UTF-8 shell configuration without null characters is supported.",
            "The shell configuration exceeds 2 MB. Use an external editor.",
            "zsh syntax validation failed. Review the configuration before retrying. The file has not been saved.",
            "Terminal could not be opened. Check that Terminal is available, then try again."
        ],
        .zhHans: [
            "无法安全读取 hosts。请检查文件类型和权限。",
            "hosts 超过 64 KB 编辑限制。请使用外部编辑器。",
            "hosts 草稿中的 IP 地址或域名格式不正确。请检查所示行后保存。",
            "请保留这些系统映射：127.0.0.1 localhost、::1 localhost 和 255.255.255.255 broadcasthost。",
            "hosts 未能保存。请检查管理员授权，当前草稿已保留。",
            "测试模式下不会修改系统配置。",
            "文件已在 Nori 外发生变化。请重新载入当前文件后保存，草稿已保留。",
            "变量名须以字母或下划线开头，且仅包含字母、数字或下划线；值不能换行。",
            "请在完整配置文件中编辑动态或复杂的变量声明。",
            "仅支持不含空字符的 UTF-8 Shell 配置。",
            "Shell 配置超过 2 MB。请使用外部编辑器。",
            "zsh 语法检查未通过。请检查配置后重试，文件尚未保存。",
            "无法打开 Terminal。请确认 Terminal 可用后重试。"
        ],
        .zhHant: [
            "無法安全讀取 hosts。請檢查檔案類型和權限。",
            "hosts 超過 64 KB 編輯限制。請使用外部編輯器。",
            "hosts 草稿中的 IP 位址或網域名稱格式不正確。請檢查所示行後儲存。",
            "請保留這些系統映射：127.0.0.1 localhost、::1 localhost 和 255.255.255.255 broadcasthost。",
            "hosts 未能儲存。請檢查管理員授權，目前草稿已保留。",
            "測試模式下不會修改系統設定。",
            "檔案已在 Nori 外發生變更。請重新載入目前檔案後儲存，草稿已保留。",
            "變數名稱須以字母或底線開頭，且僅包含字母、數字或底線；值不能換行。",
            "請在完整設定檔中編輯動態或複雜的變數宣告。",
            "僅支援不含空字元的 UTF-8 Shell 設定。",
            "Shell 設定超過 2 MB。請使用外部編輯器。",
            "zsh 語法檢查未通過。請檢查設定後重試，檔案尚未儲存。",
            "無法開啟 Terminal。請確認 Terminal 可用後重試。"
        ],
        .ja: [
            "hosts を安全に読み取れません。ファイルの種類と権限を確認してください。",
            "hosts が編集上限の 64 KB を超えています。外部エディタを使用してください。",
            "hosts の下書きに無効な IP アドレスまたはホスト名があります。指定された行を確認してから保存してください。",
            "次のシステム設定を保持してください: 127.0.0.1 localhost、::1 localhost、255.255.255.255 broadcasthost。",
            "hosts を保存できませんでした。管理者認証を確認してください。下書きは保持されています。",
            "テストモードではシステム設定を変更しません。",
            "Nori の外でファイルが変更されました。現在のファイルを再読み込みしてから保存してください。下書きは保持されています。",
            "変数名は英字またはアンダースコアで始め、英数字とアンダースコアのみを使用してください。値に改行は使用できません。",
            "動的または複雑な変数の宣言は設定ファイル全体で編集してください。",
            "ヌル文字を含まない UTF-8 の Shell 設定のみ対応しています。",
            "Shell 設定が 2 MB を超えています。外部エディタを使用してください。",
            "zsh の構文チェックに失敗しました。設定を確認してから再試行してください。ファイルは保存されていません。",
            "Terminal を開けませんでした。Terminal が利用可能か確認してから再試行してください。"
        ],
        .ko: [
            "hosts 파일을 안전하게 읽을 수 없습니다. 파일 유형과 권한을 확인하세요.",
            "hosts 파일이 편집 제한인 64 KB를 초과합니다. 외부 편집기를 사용하세요.",
            "hosts 초안에 잘못된 IP 주소 또는 호스트 이름이 있습니다. 표시된 줄을 확인한 후 저장하세요.",
            "다음 시스템 매핑을 유지하세요: 127.0.0.1 localhost, ::1 localhost, 255.255.255.255 broadcasthost.",
            "hosts 파일을 저장하지 못했습니다. 관리자 승인을 확인하세요. 초안은 유지되었습니다.",
            "테스트 모드에서는 시스템 설정을 변경하지 않습니다.",
            "Nori 외부에서 파일이 변경되었습니다. 현재 파일을 다시 불러온 후 저장하세요. 초안은 유지되었습니다.",
            "변수 이름은 문자 또는 밑줄로 시작하고 문자, 숫자, 밑줄만 포함해야 합니다. 값에 줄바꿈을 넣을 수 없습니다.",
            "동적이거나 복잡한 변수 선언은 전체 설정 파일에서 편집하세요.",
            "널 문자가 없는 UTF-8 Shell 설정만 지원됩니다.",
            "Shell 설정이 2 MB를 초과합니다. 외부 편집기를 사용하세요.",
            "zsh 구문 검사에 실패했습니다. 설정을 확인한 후 다시 시도하세요. 파일은 저장되지 않았습니다.",
            "Terminal을 열지 못했습니다. Terminal을 사용할 수 있는지 확인한 후 다시 시도하세요."
        ],
        .de: [
            "Die hosts-Datei kann nicht sicher gelesen werden. Prüfe Dateityp und Berechtigungen.",
            "Die hosts-Datei überschreitet das Editorlimit von 64 KB. Verwende einen externen Editor.",
            "Der hosts-Entwurf enthält eine ungültige IP-Adresse oder einen ungültigen Hostnamen. Prüfe vor dem Speichern die angegebene Zeile.",
            "Behalte diese Systemzuordnungen: 127.0.0.1 localhost, ::1 localhost und 255.255.255.255 broadcasthost.",
            "Die hosts-Datei konnte nicht gespeichert werden. Prüfe die Administratorfreigabe. Dein Entwurf wurde behalten.",
            "Systemänderungen sind im Testmodus deaktiviert.",
            "Die Datei wurde außerhalb von Nori geändert. Lade vor dem Speichern die aktuelle Datei neu. Dein Entwurf wurde behalten.",
            "Variablennamen müssen mit einem Buchstaben oder Unterstrich beginnen und dürfen nur Buchstaben, Ziffern und Unterstriche enthalten. Werte dürfen keine Zeilenumbrüche enthalten.",
            "Bearbeite dynamische oder komplexe Variablendeklarationen in der vollständigen Quelldatei.",
            "Nur UTF-8-Shell-Konfigurationen ohne Nullzeichen werden unterstützt.",
            "Die Shell-Konfiguration überschreitet 2 MB. Verwende einen externen Editor.",
            "Die zsh-Syntaxprüfung ist fehlgeschlagen. Prüfe die Konfiguration vor einem erneuten Versuch. Die Datei wurde nicht gespeichert.",
            "Terminal konnte nicht geöffnet werden. Prüfe, ob Terminal verfügbar ist, und versuche es erneut."
        ],
        .fr: [
            "Impossible de lire le fichier hosts en toute sécurité. Vérifiez son type et ses autorisations.",
            "Le fichier hosts dépasse la limite de 64 Ko de l’éditeur. Utilisez un éditeur externe.",
            "Le brouillon hosts contient une adresse IP ou un nom d’hôte invalide. Vérifiez la ligne indiquée avant d’enregistrer.",
            "Conservez ces correspondances système : 127.0.0.1 localhost, ::1 localhost et 255.255.255.255 broadcasthost.",
            "Impossible d’enregistrer le fichier hosts. Vérifiez l’autorisation administrateur. Votre brouillon a été conservé.",
            "Les modifications système sont désactivées en mode test.",
            "Le fichier a changé en dehors de Nori. Rechargez le fichier actuel avant d’enregistrer. Votre brouillon a été conservé.",
            "Les noms de variables doivent commencer par une lettre ou un trait de soulignement et ne contenir que des lettres, chiffres ou traits de soulignement. Les valeurs ne peuvent pas contenir de sauts de ligne.",
            "Modifiez les déclarations de variables dynamiques ou complexes dans le fichier source complet.",
            "Seules les configurations Shell UTF-8 sans caractère nul sont prises en charge.",
            "La configuration Shell dépasse 2 Mo. Utilisez un éditeur externe.",
            "La vérification de syntaxe zsh a échoué. Vérifiez la configuration avant de réessayer. Le fichier n’a pas été enregistré.",
            "Impossible d’ouvrir Terminal. Vérifiez que Terminal est disponible, puis réessayez."
        ],
        .es: [
            "No se puede leer el archivo hosts de forma segura. Comprueba el tipo de archivo y sus permisos.",
            "El archivo hosts supera el límite de 64 KB del editor. Usa un editor externo.",
            "El borrador hosts contiene una dirección IP o un nombre de host no válido. Revisa la línea indicada antes de guardar.",
            "Conserva estas asignaciones del sistema: 127.0.0.1 localhost, ::1 localhost y 255.255.255.255 broadcasthost.",
            "No se pudo guardar el archivo hosts. Comprueba la autorización de administrador. Se ha conservado el borrador.",
            "Los cambios del sistema están desactivados en el modo de prueba.",
            "El archivo cambió fuera de Nori. Vuelve a cargar el archivo actual antes de guardar. Se ha conservado el borrador.",
            "Los nombres de variables deben empezar con una letra o un guion bajo y contener solo letras, números o guiones bajos. Los valores no pueden contener saltos de línea.",
            "Edita las declaraciones de variables dinámicas o complejas en el archivo fuente completo.",
            "Solo se admite configuración Shell UTF-8 sin caracteres nulos.",
            "La configuración Shell supera los 2 MB. Usa un editor externo.",
            "La validación de sintaxis de zsh falló. Revisa la configuración antes de reintentarlo. El archivo no se ha guardado.",
            "No se pudo abrir Terminal. Comprueba que esté disponible e inténtalo de nuevo."
        ],
        .pt: [
            "Não é possível ler o arquivo hosts com segurança. Confira o tipo de arquivo e suas permissões.",
            "O arquivo hosts excede o limite de 64 KB do editor. Use um editor externo.",
            "O rascunho hosts contém um endereço IP ou nome de host inválido. Confira a linha indicada antes de salvar.",
            "Mantenha estes mapeamentos do sistema: 127.0.0.1 localhost, ::1 localhost e 255.255.255.255 broadcasthost.",
            "Não foi possível salvar o arquivo hosts. Confira a autorização de administrador. Seu rascunho foi mantido.",
            "Alterações do sistema estão desativadas no modo de teste.",
            "O arquivo mudou fora do Nori. Recarregue o arquivo atual antes de salvar. Seu rascunho foi mantido.",
            "Nomes de variáveis devem começar com uma letra ou sublinhado e conter apenas letras, números ou sublinhados. Os valores não podem conter quebras de linha.",
            "Edite declarações de variáveis dinâmicas ou complexas no arquivo-fonte completo.",
            "Somente configurações Shell UTF-8 sem caracteres nulos são compatíveis.",
            "A configuração Shell excede 2 MB. Use um editor externo.",
            "A validação de sintaxe do zsh falhou. Confira a configuração antes de tentar novamente. O arquivo não foi salvo.",
            "Não foi possível abrir o Terminal. Confira se ele está disponível e tente novamente."
        ],
        .it: [
            "Impossibile leggere il file hosts in modo sicuro. Controlla il tipo di file e i permessi.",
            "Il file hosts supera il limite di 64 KB dell’editor. Usa un editor esterno.",
            "La bozza hosts contiene un indirizzo IP o un nome host non valido. Controlla la riga indicata prima di salvare.",
            "Mantieni queste associazioni di sistema: 127.0.0.1 localhost, ::1 localhost e 255.255.255.255 broadcasthost.",
            "Impossibile salvare il file hosts. Controlla l’autorizzazione amministratore. La bozza è stata mantenuta.",
            "Le modifiche di sistema sono disattivate in modalità test.",
            "Il file è cambiato al di fuori di Nori. Ricarica il file attuale prima di salvare. La bozza è stata mantenuta.",
            "I nomi delle variabili devono iniziare con una lettera o un trattino basso e contenere solo lettere, numeri o trattini bassi. I valori non possono contenere nuove righe.",
            "Modifica le dichiarazioni di variabili dinamiche o complesse nel file sorgente completo.",
            "Sono supportate solo configurazioni Shell UTF-8 senza caratteri nulli.",
            "La configurazione Shell supera 2 MB. Usa un editor esterno.",
            "La verifica della sintassi zsh non è riuscita. Controlla la configurazione prima di riprovare. Il file non è stato salvato.",
            "Impossibile aprire Terminal. Verifica che sia disponibile, poi riprova."
        ],
        .ru: [
            "Не удалось безопасно прочитать файл hosts. Проверьте тип файла и права доступа.",
            "Файл hosts превышает ограничение редактора в 64 КБ. Используйте внешний редактор.",
            "Черновик hosts содержит неверный IP-адрес или имя хоста. Проверьте указанную строку перед сохранением.",
            "Сохраните системные соответствия: 127.0.0.1 localhost, ::1 localhost и 255.255.255.255 broadcasthost.",
            "Не удалось сохранить файл hosts. Проверьте права администратора. Черновик сохранён.",
            "Изменения системы отключены в тестовом режиме.",
            "Файл изменился вне Nori. Загрузите текущий файл заново перед сохранением. Черновик сохранён.",
            "Имена переменных должны начинаться с буквы или подчёркивания и содержать только буквы, цифры или подчёркивания. Значения не могут содержать переводы строк.",
            "Редактируйте динамические или сложные объявления переменных в полном исходном файле.",
            "Поддерживается только конфигурация Shell в UTF-8 без нулевых символов.",
            "Конфигурация Shell превышает 2 МБ. Используйте внешний редактор.",
            "Проверка синтаксиса zsh не пройдена. Проверьте конфигурацию перед повторной попыткой. Файл не сохранён.",
            "Не удалось открыть Terminal. Проверьте его доступность и повторите попытку."
        ],
        .tr: [
            "hosts dosyası güvenli şekilde okunamıyor. Dosya türünü ve izinlerini kontrol edin.",
            "hosts dosyası düzenleyicinin 64 KB sınırını aşıyor. Harici bir düzenleyici kullanın.",
            "hosts taslağı geçersiz bir IP adresi veya ana makine adı içeriyor. Kaydetmeden önce belirtilen satırı kontrol edin.",
            "Şu sistem eşlemelerini koruyun: 127.0.0.1 localhost, ::1 localhost ve 255.255.255.255 broadcasthost.",
            "hosts dosyası kaydedilemedi. Yönetici yetkisini kontrol edin. Taslağınız korundu.",
            "Test modunda sistem değişiklikleri devre dışıdır.",
            "Dosya Nori dışında değişti. Kaydetmeden önce güncel dosyayı yeniden yükleyin. Taslağınız korundu.",
            "Değişken adları harf veya alt çizgiyle başlamalı ve yalnızca harf, rakam veya alt çizgi içermelidir. Değerler satır sonu içeremez.",
            "Dinamik veya karmaşık değişken bildirimlerini tam kaynak dosyasında düzenleyin.",
            "Yalnızca boş karakter içermeyen UTF-8 Shell yapılandırması desteklenir.",
            "Shell yapılandırması 2 MB sınırını aşıyor. Harici bir düzenleyici kullanın.",
            "zsh sözdizimi doğrulaması başarısız oldu. Tekrar denemeden önce yapılandırmayı kontrol edin. Dosya kaydedilmedi.",
            "Terminal açılamadı. Terminal’in kullanılabilir olduğunu kontrol edip tekrar deneyin."
        ]
    ]

    private static let summaryKeys = [
        "cleanup.execution.summary", "cleanup.execution.summary.permanent", "cleanup.execution.maintenance",
        "cleanup.execution.incomplete", "cleanup.execution.verificationIncomplete", "agents.status.incomplete",
        "agents.status.leftovers", "log.scanPartial"
    ]

    private static let summaryTranslations: [AppLanguage: [String]] = [
        .en: [
            "Handled %d · skipped %d · failed %d",
            "Permanently cleaned %d · skipped %d · failed %d",
            "Maintenance completed %d · skipped %d · failed %d",
            "The cleanup task did not finish. Review the details and try again.",
            "Some remaining paths could not be verified. Scan again to update their sizes and selection.",
            "Some items were kept. Review the details, close the related agents if needed, then scan again.",
            "%@ was uninstalled. Scan the Cleanup page to find its remaining data.",
            "Scan partially completed. Review the available results."
        ],
        .zhHans: [
            "已处理 %d · 跳过 %d · 失败 %d",
            "已永久清理 %d · 跳过 %d · 失败 %d",
            "维护完成 %d · 跳过 %d · 失败 %d",
            "清理任务未完成。请查看原因后重试。",
            "部分剩余路径无法完成复核。请重新扫描以更新容量与选择。",
            "部分项目已保留。请查看详情，按需退出相关 Agent 后重新扫描。",
            "%@ 已卸载。请在「清理」页扫描其残留数据。",
            "扫描部分完成。请查看可用结果。"
        ],
        .zhHant: [
            "已處理 %d · 略過 %d · 失敗 %d",
            "已永久清理 %d · 略過 %d · 失敗 %d",
            "維護完成 %d · 略過 %d · 失敗 %d",
            "清理工作未完成。請查看原因後重試。",
            "部分剩餘路徑無法完成複核。請重新掃描以更新容量與選取項目。",
            "部分項目已保留。請查看詳細資訊，視需要結束相關 Agent 後重新掃描。",
            "%@ 已解除安裝。請在「清理」頁掃描其殘留資料。",
            "掃描部分完成。請查看可用結果。"
        ],
        .ja: [
            "処理済み %d · スキップ %d · 失敗 %d",
            "完全にクリーンアップ %d · スキップ %d · 失敗 %d",
            "メンテナンス完了 %d · スキップ %d · 失敗 %d",
            "クリーンアップが完了しませんでした。詳細を確認してから再試行してください。",
            "一部の残りのパスを確認できませんでした。再スキャンして容量と選択を更新してください。",
            "一部の項目を保持しました。詳細を確認し、必要に応じて関連する Agent を終了してから再スキャンしてください。",
            "%@ をアンインストールしました。「クリーンアップ」で残りのデータをスキャンしてください。",
            "スキャンが一部完了しました。利用可能な結果を確認してください。"
        ],
        .ko: [
            "처리 %d · 건너뜀 %d · 실패 %d",
            "영구 정리 %d · 건너뜀 %d · 실패 %d",
            "유지 관리 완료 %d · 건너뜀 %d · 실패 %d",
            "정리 작업이 완료되지 않았습니다. 세부 정보를 확인한 후 다시 시도하세요.",
            "일부 남은 경로를 확인하지 못했습니다. 크기와 선택 항목을 업데이트하려면 다시 스캔하세요.",
            "일부 항목을 유지했습니다. 세부 정보를 확인하고 필요하면 관련 Agent를 종료한 후 다시 스캔하세요.",
            "%@을(를) 제거했습니다. 정리 페이지에서 남은 데이터를 스캔하세요.",
            "스캔이 일부 완료되었습니다. 사용 가능한 결과를 확인하세요."
        ],
        .de: [
            "Bearbeitet %d · übersprungen %d · fehlgeschlagen %d",
            "Dauerhaft bereinigt %d · übersprungen %d · fehlgeschlagen %d",
            "Wartung abgeschlossen %d · übersprungen %d · fehlgeschlagen %d",
            "Die Bereinigung wurde nicht abgeschlossen. Prüfe die Details und versuche es erneut.",
            "Einige verbleibende Pfade konnten nicht geprüft werden. Scanne erneut, um Größen und Auswahl zu aktualisieren.",
            "Einige Elemente wurden behalten. Prüfe die Details, beende bei Bedarf die zugehörigen Agents und scanne erneut.",
            "%@ wurde deinstalliert. Scanne im Bereich Bereinigung nach verbleibenden Daten.",
            "Der Scan wurde teilweise abgeschlossen. Prüfe die verfügbaren Ergebnisse."
        ],
        .fr: [
            "Traités %d · ignorés %d · échecs %d",
            "Nettoyés définitivement %d · ignorés %d · échecs %d",
            "Maintenance terminée %d · ignorés %d · échecs %d",
            "Le nettoyage n’a pas abouti. Consultez les détails, puis réessayez.",
            "Certains chemins restants n’ont pas pu être vérifiés. Relancez l’analyse pour actualiser les tailles et la sélection.",
            "Certains éléments ont été conservés. Consultez les détails, quittez les agents associés si nécessaire, puis relancez l’analyse.",
            "%@ a été désinstallé. Lancez une analyse dans Nettoyage pour trouver ses données restantes.",
            "L’analyse est partiellement terminée. Consultez les résultats disponibles."
        ],
        .es: [
            "Procesados %d · omitidos %d · fallidos %d",
            "Limpiados permanentemente %d · omitidos %d · fallidos %d",
            "Mantenimiento completado %d · omitidos %d · fallidos %d",
            "La limpieza no se completó. Revisa los detalles e inténtalo de nuevo.",
            "No se pudieron verificar algunas rutas restantes. Vuelve a analizar para actualizar los tamaños y la selección.",
            "Se conservaron algunos elementos. Revisa los detalles, cierra los agentes relacionados si es necesario y vuelve a analizar.",
            "%@ se ha desinstalado. Analiza la página Limpieza para encontrar sus datos restantes.",
            "El análisis se completó parcialmente. Revisa los resultados disponibles."
        ],
        .pt: [
            "Processados %d · ignorados %d · falhas %d",
            "Limpos permanentemente %d · ignorados %d · falhas %d",
            "Manutenção concluída %d · ignorados %d · falhas %d",
            "A limpeza não foi concluída. Confira os detalhes e tente novamente.",
            "Alguns caminhos restantes não puderam ser verificados. Analise novamente para atualizar os tamanhos e a seleção.",
            "Alguns itens foram mantidos. Confira os detalhes, feche os agentes relacionados se necessário e analise novamente.",
            "%@ foi desinstalado. Analise a página Limpeza para encontrar os dados restantes.",
            "A análise foi parcialmente concluída. Confira os resultados disponíveis."
        ],
        .it: [
            "Elaborati %d · ignorati %d · non riusciti %d",
            "Puliti definitivamente %d · ignorati %d · non riusciti %d",
            "Manutenzione completata %d · ignorati %d · non riusciti %d",
            "La pulizia non è stata completata. Controlla i dettagli e riprova.",
            "Impossibile verificare alcuni percorsi rimanenti. Ripeti la scansione per aggiornare dimensioni e selezione.",
            "Alcuni elementi sono stati mantenuti. Controlla i dettagli, chiudi gli agent associati se necessario, poi ripeti la scansione.",
            "%@ è stato disinstallato. Esegui una scansione nella pagina Pulizia per trovare i dati rimanenti.",
            "La scansione è parzialmente completata. Controlla i risultati disponibili."
        ],
        .ru: [
            "Обработано %d · пропущено %d · ошибок %d",
            "Очищено безвозвратно %d · пропущено %d · ошибок %d",
            "Обслуживание завершено %d · пропущено %d · ошибок %d",
            "Очистка не завершена. Ознакомьтесь с подробностями и повторите попытку.",
            "Не удалось проверить некоторые оставшиеся пути. Сканируйте снова, чтобы обновить размеры и выбор.",
            "Некоторые объекты сохранены. Ознакомьтесь с подробностями, при необходимости закройте связанные агенты и сканируйте снова.",
            "%@ удалён. Сканируйте страницу «Очистка», чтобы найти оставшиеся данные.",
            "Сканирование завершено частично. Ознакомьтесь с доступными результатами."
        ],
        .tr: [
            "İşlenen %d · atlanan %d · başarısız %d",
            "Kalıcı olarak temizlenen %d · atlanan %d · başarısız %d",
            "Bakımı tamamlanan %d · atlanan %d · başarısız %d",
            "Temizleme görevi tamamlanmadı. Ayrıntıları inceleyip tekrar deneyin.",
            "Kalan bazı yollar doğrulanamadı. Boyutları ve seçimi güncellemek için yeniden tarayın.",
            "Bazı öğeler korundu. Ayrıntıları inceleyin, gerekirse ilgili agent’ları kapatın ve yeniden tarayın.",
            "%@ kaldırıldı. Kalan verileri bulmak için Temizleme sayfasında tarama yapın.",
            "Tarama kısmen tamamlandı. Mevcut sonuçları inceleyin."
        ]
    ]

    private static let remainingKeys = ["task.closeApps.remaining", "task.failure.runtimeRemaining"]
    private static let remainingTranslations: [AppLanguage: [String]] = [
        .en: [
            "The items that could be cleaned have been processed. Some selected items are still in use. Save your work and fully quit the applications or related CLI processes below, then check again to continue with the remaining items.",
            "The items that could be cleaned have been processed. Some remaining items were kept because their process state could not be reliably checked. Try again to continue with those items."
        ],
        .zhHans: [
            "可清理的项目已处理。部分所选项目仍在使用。请保存工作并完全退出下列应用或相关 CLI 进程，再重新检查以继续处理剩余项目。",
            "可清理的项目已处理。部分剩余项目因无法可靠确认进程状态而暂时保留。请重试以继续处理这些项目。"
        ],
        .zhHant: [
            "可清理的項目已處理。部分所選項目仍在使用。請儲存工作並完全結束下列應用程式或相關 CLI 程序，再重新檢查以繼續處理剩餘項目。",
            "可清理的項目已處理。部分剩餘項目因無法可靠確認程序狀態而暫時保留。請重試以繼續處理這些項目。"
        ],
        .ja: [
            "クリーンアップできる項目は処理しました。一部の選択項目は使用中です。作業を保存し、以下のアプリまたは関連する CLI プロセスを完全に終了してから再確認し、残りの項目を処理してください。",
            "クリーンアップできる項目は処理しました。プロセスの状態を確実に確認できなかったため、一部の項目を保持しました。再試行して残りの項目を処理してください。"
        ],
        .ko: [
            "정리할 수 있는 항목은 처리했습니다. 일부 선택 항목은 아직 사용 중입니다. 작업을 저장하고 아래 앱 또는 관련 CLI 프로세스를 완전히 종료한 후 다시 확인하여 남은 항목을 처리하세요.",
            "정리할 수 있는 항목은 처리했습니다. 프로세스 상태를 확실하게 확인할 수 없어 일부 항목을 유지했습니다. 다시 시도하여 남은 항목을 처리하세요."
        ],
        .de: [
            "Die bereinigbaren Elemente wurden verarbeitet. Einige ausgewählte Elemente werden noch verwendet. Speichere deine Arbeit und beende die folgenden Apps oder zugehörigen CLI-Prozesse vollständig. Prüfe danach erneut, um die verbleibenden Elemente zu bearbeiten.",
            "Die bereinigbaren Elemente wurden verarbeitet. Einige verbleibende Elemente wurden behalten, weil ihr Prozessstatus nicht zuverlässig geprüft werden konnte. Versuche es erneut, um diese Elemente zu bearbeiten."
        ],
        .fr: [
            "Les éléments pouvant être nettoyés ont été traités. Certains éléments sélectionnés sont encore utilisés. Enregistrez votre travail, quittez complètement les applications ou processus CLI associés ci-dessous, puis vérifiez à nouveau pour traiter les éléments restants.",
            "Les éléments pouvant être nettoyés ont été traités. Certains éléments restants ont été conservés car l’état de leurs processus n’a pas pu être vérifié de façon fiable. Réessayez pour traiter ces éléments."
        ],
        .es: [
            "Se han procesado los elementos que podían limpiarse. Algunos elementos seleccionados siguen en uso. Guarda tu trabajo y cierra por completo las aplicaciones o los procesos CLI relacionados que aparecen abajo. Después vuelve a comprobarlo para procesar los elementos restantes.",
            "Se han procesado los elementos que podían limpiarse. Se conservaron algunos elementos restantes porque no se pudo comprobar de forma fiable el estado de sus procesos. Vuelve a intentarlo para procesarlos."
        ],
        .pt: [
            "Os itens que podiam ser limpos foram processados. Alguns itens selecionados ainda estão em uso. Salve seu trabalho e encerre completamente os aplicativos ou processos CLI relacionados abaixo. Depois verifique novamente para processar os itens restantes.",
            "Os itens que podiam ser limpos foram processados. Alguns itens restantes foram mantidos porque o estado de seus processos não pôde ser verificado com segurança. Tente novamente para processá-los."
        ],
        .it: [
            "Gli elementi che potevano essere puliti sono stati elaborati. Alcuni elementi selezionati sono ancora in uso. Salva il lavoro e chiudi completamente le app o i processi CLI associati qui sotto. Poi controlla di nuovo per elaborare gli elementi rimanenti.",
            "Gli elementi che potevano essere puliti sono stati elaborati. Alcuni elementi rimanenti sono stati mantenuti perché non è stato possibile verificarne in modo affidabile lo stato dei processi. Riprova per elaborarli."
        ],
        .ru: [
            "Объекты, которые можно было очистить, обработаны. Некоторые выбранные объекты ещё используются. Сохраните работу и полностью завершите указанные приложения или связанные процессы CLI. Затем проверьте снова, чтобы обработать оставшиеся объекты.",
            "Объекты, которые можно было очистить, обработаны. Некоторые оставшиеся объекты сохранены, поскольку состояние их процессов не удалось надёжно проверить. Повторите попытку, чтобы обработать их."
        ],
        .tr: [
            "Temizlenebilen öğeler işlendi. Seçilen bazı öğeler hâlâ kullanılıyor. Çalışmanızı kaydedin ve aşağıdaki uygulamaları veya ilgili CLI işlemlerini tamamen kapatın. Kalan öğeleri işlemek için yeniden kontrol edin.",
            "Temizlenebilen öğeler işlendi. İşlem durumları güvenilir şekilde kontrol edilemediğinden kalan bazı öğeler korundu. Bu öğeleri işlemek için tekrar deneyin."
        ]
    ]
}
