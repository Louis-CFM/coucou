#!/usr/bin/env python3
"""Add hub.section.memory and related memory strings to Localizable.xcstrings."""

import json
import sys
from pathlib import Path

XCSTRINGS = Path(__file__).parent.parent / "NotchBuddy/Resources/Localizable.xcstrings"

STRINGS = {
    "hub.section.memory": {
        "en": "Memory", "fr": "Mémoire", "zh-Hant": "記憶", "de": "Erinnerung",
        "es": "Memoria", "ja": "メモリ", "ko": "메모리", "ar": "الذاكرة",
        "zh-Hans": "记忆", "ru": "Память", "pt-BR": "Memória", "hi": "स्मृति",
        "id": "Memori", "tr": "Bellek", "bn": "স্মৃতি", "th": "หน่วยความจำ",
    },
    "hub.page.memory-search": {
        "en": "Search", "fr": "Rechercher", "zh-Hant": "搜索", "de": "Suche",
        "es": "Buscar", "ja": "検索", "ko": "검색", "ar": "بحث",
        "zh-Hans": "搜索", "ru": "Поиск", "pt-BR": "Pesquisar", "hi": "खोजें",
        "id": "Cari", "tr": "Ara", "bn": "অনুসন্ধান", "th": "ค้นหา",
    },
    "hub.page.memory-graph": {
        "en": "Graph", "fr": "Graphe", "zh-Hant": "圖譜", "de": "Graph",
        "es": "Grafo", "ja": "グラフ", "ko": "그래프", "ar": "رسم بياني",
        "zh-Hans": "图谱", "ru": "Граф", "pt-BR": "Grafo", "hi": "ग्राफ़",
        "id": "Graf", "tr": "Grafik", "bn": "গ্রাফ", "th": "กราฟ",
    },
    "hub.page.memory-recurrences": {
        "en": "Patterns", "fr": "Récurrences", "zh-Hant": "模式", "de": "Muster",
        "es": "Patrones", "ja": "パターン", "ko": "패턴", "ar": "أنماط",
        "zh-Hans": "模式", "ru": "Паттерны", "pt-BR": "Padrões", "hi": "पैटर्न",
        "id": "Pola", "tr": "Kalıplar", "bn": "প্যাটার্ন", "th": "รูปแบบ",
    },
    "hub.page.memory-settings": {
        "en": "Sources", "fr": "Sources", "zh-Hant": "來源", "de": "Quellen",
        "es": "Fuentes", "ja": "ソース", "ko": "소스", "ar": "المصادر",
        "zh-Hans": "来源", "ru": "Источники", "pt-BR": "Fontes", "hi": "स्रोत",
        "id": "Sumber", "tr": "Kaynaklar", "bn": "উৎস", "th": "แหล่งที่มา",
    },
    "hub.memory.search.placeholder": {
        "en": "Search…", "fr": "Chercher…", "zh-Hant": "搜索…", "de": "Suchen…",
        "es": "Buscar…", "ja": "検索…", "ko": "검색…", "ar": "بحث…",
        "zh-Hans": "搜索…", "ru": "Поиск…", "pt-BR": "Pesquisar…", "hi": "खोजें…",
        "id": "Cari…", "tr": "Ara…", "bn": "অনুসন্ধান…", "th": "ค้นหา…",
    },
    "hub.memory.search.load-more": {
        "en": "See more", "fr": "Voir plus", "zh-Hant": "查看更多", "de": "Mehr anzeigen",
        "es": "Ver más", "ja": "もっと見る", "ko": "더 보기", "ar": "عرض المزيد",
        "zh-Hans": "查看更多", "ru": "Больше", "pt-BR": "Ver mais", "hi": "और देखें",
        "id": "Lihat lagi", "tr": "Daha fazla", "bn": "আরও দেখুন", "th": "ดูเพิ่มเติม",
    },
    "hub.memory.not-installed": {
        "en": "Brain not installed", "fr": "Brain non installé", "zh-Hant": "Brain 未安裝",
        "de": "Brain nicht installiert", "es": "Brain no instalado",
        "ja": "Brainが未インストール", "ko": "Brain 미설치", "ar": "Brain غير مثبت",
        "zh-Hans": "Brain 未安装", "ru": "Brain не установлен", "pt-BR": "Brain não instalado",
        "hi": "Brain इंस्टॉल नहीं है", "id": "Brain belum dipasang",
        "tr": "Brain kurulu değil", "bn": "Brain ইনস্টল নেই", "th": "Brain ไม่ได้ติดตั้ง",
    },
    "hub.memory.not-installed.detail": {
        "en": "brain is an optional tool for indexing your Claude conversations. Install it with:",
        "fr": "brain est un outil optionnel pour indexer vos conversations Claude. Installez-le avec :",
        "zh-Hant": "brain 是索引 Claude 對話的可選工具。安裝方式：",
        "de": "brain ist ein optionales Tool zum Indexieren. Installieren mit:",
        "es": "brain es una herramienta opcional para indexar conversaciones. Instalar con:",
        "ja": "brainはClaude会話をインデックスするオプションのツールです。インストール：",
        "ko": "brain은 선택적 도구입니다. 설치:",
        "ar": "brain أداة اختيارية. التثبيت:",
        "zh-Hans": "brain 是可选工具。安装方式：",
        "ru": "brain — опциональный инструмент. Установка:",
        "pt-BR": "brain é uma ferramenta opcional. Instalar com:",
        "hi": "brain एक वैकल्पिक टूल है। इंस्टॉल करें:",
        "id": "brain adalah alat opsional. Pasang dengan:",
        "tr": "brain isteğe bağlı bir araç. Yükle:",
        "bn": "brain একটি ঐচ্ছিক টুল। ইনস্টল করুন:",
        "th": "brain เป็นเครื่องมือเสริม ติดตั้งด้วย:",
    },
    "hub.memory.index-missing": {
        "en": "Index missing", "fr": "Index absent", "zh-Hant": "索引缺失",
        "de": "Index fehlt", "es": "Índice faltante", "ja": "インデックスなし",
        "ko": "인덱스 없음", "ar": "الفهرس مفقود", "zh-Hans": "索引缺失",
        "ru": "Индекс отсутствует", "pt-BR": "Índice ausente", "hi": "इंडेक्स अनुपस्थित",
        "id": "Indeks tidak ada", "tr": "Dizin eksik", "bn": "ইনডেক্স অনুপস্থিত",
        "th": "ไม่มีดัชนี",
    },
    "hub.memory.index-missing.detail": {
        "en": "Run brain index to build the search index.",
        "fr": "Lance brain index pour construire l'index de recherche.",
        "zh-Hant": "執行 brain index 以建立搜索索引。",
        "de": "Führe brain index aus.",
        "es": "Ejecuta brain index para crear el índice.",
        "ja": "brain index を実行してください。",
        "ko": "brain index 실행하세요.",
        "ar": "شغّل brain index.",
        "zh-Hans": "运行 brain index 构建索引。",
        "ru": "Запустите brain index.",
        "pt-BR": "Execute brain index.",
        "hi": "brain index चलाएं।",
        "id": "Jalankan brain index.",
        "tr": "brain index çalıştırın.",
        "bn": "brain index চালান।",
        "th": "รัน brain index",
    },
    "hub.memory.show.open-claude": {
        "en": "Open on Claude.ai", "fr": "Ouvrir sur Claude.ai", "zh-Hant": "在 Claude.ai 開啟",
        "de": "Auf Claude.ai öffnen", "es": "Abrir en Claude.ai", "ja": "Claude.aiで開く",
        "ko": "Claude.ai에서 열기", "ar": "افتح على Claude.ai", "zh-Hans": "在 Claude.ai 打开",
        "ru": "Открыть на Claude.ai", "pt-BR": "Abrir no Claude.ai", "hi": "Claude.ai पर खोलें",
        "id": "Buka di Claude.ai", "tr": "Claude.ai'de aç", "bn": "Claude.ai-তে খুলুন",
        "th": "เปิดบน Claude.ai",
    },
    "hub.memory.show.resume": {
        "en": "Resume session", "fr": "Reprendre la session", "zh-Hant": "繼續會話",
        "de": "Sitzung fortsetzen", "es": "Reanudar sesión", "ja": "セッションを再開",
        "ko": "세션 재개", "ar": "استئناف الجلسة", "zh-Hans": "继续会话",
        "ru": "Продолжить сессию", "pt-BR": "Retomar sessão", "hi": "सेशन फिर से शुरू करें",
        "id": "Lanjutkan sesi", "tr": "Oturumu sürdür", "bn": "সেশন পুনরায় শুরু করুন",
        "th": "ดำเนินเซสชันต่อ",
    },
    "hub.memory.show.chat": {
        "en": "Continue in chat", "fr": "Continuer dans le chat", "zh-Hant": "在聊天中繼續",
        "de": "Im Chat fortsetzen", "es": "Continuar en el chat", "ja": "チャットで続ける",
        "ko": "채팅에서 계속", "ar": "المتابعة في الدردشة", "zh-Hans": "在聊天中继续",
        "ru": "Продолжить в чате", "pt-BR": "Continuar no chat", "hi": "चैट में जारी रखें",
        "id": "Lanjutkan di obrolan", "tr": "Sohbette devam et", "bn": "চ্যাটে চালিয়ে যান",
        "th": "ดำเนินการในแชท",
    },
    "hub.memory.show.not-digested": {
        "en": "Not yet analyzed", "fr": "Pas encore digérée", "zh-Hant": "尚未分析",
        "de": "Noch nicht analysiert", "es": "Aún no analizada", "ja": "まだ分析されていません",
        "ko": "아직 분석되지 않음", "ar": "لم يتم التحليل بعد", "zh-Hans": "尚未分析",
        "ru": "Ещё не проанализировано", "pt-BR": "Ainda não analisado", "hi": "अभी तक विश्लेषण नहीं किया",
        "id": "Belum dianalisis", "tr": "Henüz analiz edilmedi", "bn": "এখনও বিশ্লেষণ হয়নি",
        "th": "ยังไม่ได้วิเคราะห์",
    },
    "hub.memory.show.elements": {
        "en": "Retained elements", "fr": "Éléments retenus", "zh-Hant": "已保留元素",
        "de": "Behaltene Elemente", "es": "Elementos retenidos", "ja": "保持された要素",
        "ko": "보존된 요소", "ar": "العناصر المحفوظة", "zh-Hans": "已保留元素",
        "ru": "Сохранённые элементы", "pt-BR": "Elementos retidos", "hi": "सहेजे गए तत्व",
        "id": "Elemen yang dipertahankan", "tr": "Alınan öğeler", "bn": "সংরক্ষিত উপাদান",
        "th": "องค์ประกอบที่เก็บไว้",
    },
    "hub.memory.show.related": {
        "en": "Linked to", "fr": "Relié à", "zh-Hant": "關聯至",
        "de": "Verknüpft mit", "es": "Vinculado a", "ja": "関連先",
        "ko": "연결됨", "ar": "مرتبط بـ", "zh-Hans": "关联至",
        "ru": "Связано с", "pt-BR": "Vinculado a", "hi": "से जुड़ा",
        "id": "Terhubung ke", "tr": "Bağlı:", "bn": "সংযুক্ত",
        "th": "เชื่อมโยงกับ",
    },
    "hub.memory.graph.replay": {
        "en": "Replay growth", "fr": "Voir grandir", "zh-Hant": "重播生長",
        "de": "Wachstum abspielen", "es": "Ver crecer", "ja": "成長を再生",
        "ko": "성장 재생", "ar": "إعادة تشغيل النمو", "zh-Hans": "重播增长",
        "ru": "Воспроизвести рост", "pt-BR": "Reproduzir crescimento", "hi": "विकास दोहराएं",
        "id": "Putar ulang pertumbuhan", "tr": "Büyümeyi oynat", "bn": "বৃদ্ধি দেখান",
        "th": "เล่นการเติบโตซ้ำ",
    },
    "hub.memory.graph.recenter": {
        "en": "Recenter", "fr": "Recentrer", "zh-Hant": "重新置中",
        "de": "Neu zentrieren", "es": "Recentrar", "ja": "再中央揃え",
        "ko": "다시 가운데로", "ar": "إعادة التوسيط", "zh-Hans": "重新居中",
        "ru": "Перецентрировать", "pt-BR": "Recentrar", "hi": "पुनः केंद्रित करें",
        "id": "Pusatkan ulang", "tr": "Yeniden ortala", "bn": "পুনরায় কেন্দ্রীভূত করুন",
        "th": "จัดกึ่งกลางใหม่",
    },
    "hub.memory.recurrences.habits": {
        "en": "You do it often", "fr": "Tu le fais souvent", "zh-Hant": "你經常這樣做",
        "de": "Du machst es oft", "es": "Lo haces seguido", "ja": "よくやること",
        "ko": "자주 하는 것", "ar": "تفعله كثيراً", "zh-Hans": "你经常这样做",
        "ru": "Ты часто это делаешь", "pt-BR": "Você faz com frequência", "hi": "आप अक्सर करते हैं",
        "id": "Kamu sering melakukan ini", "tr": "Bunu sık yapıyorsun", "bn": "আপনি এটি প্রায়ই করেন",
        "th": "คุณทำบ่อย",
    },
    "hub.memory.recurrences.errors": {
        "en": "Same errors", "fr": "Les mêmes erreurs", "zh-Hant": "相同錯誤",
        "de": "Gleiche Fehler", "es": "Los mismos errores", "ja": "同じエラー",
        "ko": "같은 오류", "ar": "نفس الأخطاء", "zh-Hans": "相同错误",
        "ru": "Одни и те же ошибки", "pt-BR": "Mesmos erros", "hi": "वही गलतियां",
        "id": "Kesalahan yang sama", "tr": "Aynı hatalar", "bn": "একই ভুল",
        "th": "ข้อผิดพลาดเดิม",
    },
    "hub.memory.recurrences.created": {
        "en": "What Claude created", "fr": "Ce que Claude a créé", "zh-Hant": "Claude 創建的內容",
        "de": "Was Claude erstellt hat", "es": "Lo que Claude creó", "ja": "Claudeが作成したもの",
        "ko": "Claude가 만든 것", "ar": "ما أنشأه Claude", "zh-Hans": "Claude 创建的内容",
        "ru": "Что создал Claude", "pt-BR": "O que Claude criou", "hi": "Claude ने क्या बनाया",
        "id": "Yang dibuat Claude", "tr": "Claude'un yarattıkları", "bn": "Claude যা তৈরি করেছে",
        "th": "สิ่งที่ Claude สร้าง",
    },
    "hub.memory.recurrences.make-skill": {
        "en": "Make a skill", "fr": "En faire un skill", "zh-Hant": "製作技能",
        "de": "Skill erstellen", "es": "Crear habilidad", "ja": "スキルを作る",
        "ko": "스킬 만들기", "ar": "إنشاء مهارة", "zh-Hans": "制作技能",
        "ru": "Создать навык", "pt-BR": "Criar habilidade", "hi": "स्किल बनाएं",
        "id": "Buat keahlian", "tr": "Beceri oluştur", "bn": "স্কিল তৈরি করুন",
        "th": "สร้างทักษะ",
    },
    "hub.memory.recurrences.add-claude-md": {
        "en": "Add to CLAUDE.md", "fr": "Ajouter au CLAUDE.md", "zh-Hant": "添加至 CLAUDE.md",
        "de": "Zu CLAUDE.md hinzufügen", "es": "Añadir a CLAUDE.md", "ja": "CLAUDE.mdに追加",
        "ko": "CLAUDE.md에 추가", "ar": "أضف إلى CLAUDE.md", "zh-Hans": "添加到 CLAUDE.md",
        "ru": "Добавить в CLAUDE.md", "pt-BR": "Adicionar ao CLAUDE.md", "hi": "CLAUDE.md में जोड़ें",
        "id": "Tambah ke CLAUDE.md", "tr": "CLAUDE.md'ye ekle", "bn": "CLAUDE.md-তে যোগ করুন",
        "th": "เพิ่มใน CLAUDE.md",
    },
    "hub.memory.settings.sources": {
        "en": "Sources", "fr": "Sources", "zh-Hant": "來源", "de": "Quellen",
        "es": "Fuentes", "ja": "ソース", "ko": "소스", "ar": "المصادر",
        "zh-Hans": "来源", "ru": "Источники", "pt-BR": "Fontes", "hi": "स्रोत",
        "id": "Sumber", "tr": "Kaynaklar", "bn": "উৎস", "th": "แหล่งที่มา",
    },
    "hub.memory.settings.depth": {
        "en": "Reading depth", "fr": "Jusqu'où Claude lit", "zh-Hant": "閱讀深度",
        "de": "Lesetiefe", "es": "Profundidad de lectura", "ja": "読み込み深度",
        "ko": "읽기 깊이", "ar": "عمق القراءة", "zh-Hans": "读取深度",
        "ru": "Глубина чтения", "pt-BR": "Profundidade de leitura", "hi": "पढ़ने की गहराई",
        "id": "Kedalaman membaca", "tr": "Okuma derinliği", "bn": "পড়ার গভীরতা",
        "th": "ความลึกในการอ่าน",
    },
    "hub.memory.settings.hooks": {
        "en": "What Claude Code receives", "fr": "Ce que Claude Code reçoit",
        "zh-Hant": "Claude Code 接收的內容", "de": "Was Claude Code erhält",
        "es": "Lo que Claude Code recibe", "ja": "Claude Codeが受け取るもの",
        "ko": "Claude Code가 받는 것", "ar": "ما يتلقاه Claude Code",
        "zh-Hans": "Claude Code 接收的内容", "ru": "Что получает Claude Code",
        "pt-BR": "O que Claude Code recebe", "hi": "Claude Code को क्या मिलता है",
        "id": "Yang diterima Claude Code", "tr": "Claude Code'un aldıkları",
        "bn": "Claude Code কী পায়", "th": "สิ่งที่ Claude Code ได้รับ",
    },
    "hub.memory.settings.privacy": {
        "en": "Privacy", "fr": "Confidentialité", "zh-Hant": "隱私",
        "de": "Datenschutz", "es": "Privacidad", "ja": "プライバシー",
        "ko": "개인 정보", "ar": "الخصوصية", "zh-Hans": "隐私",
        "ru": "Конфиденциальность", "pt-BR": "Privacidade", "hi": "गोपनीयता",
        "id": "Privasi", "tr": "Gizlilik", "bn": "গোপনীয়তা",
        "th": "ความเป็นส่วนตัว",
    },
    "hub.memory.settings.import": {
        "en": "Import Claude.ai export", "fr": "Importer un export Claude.ai",
        "zh-Hant": "匯入 Claude.ai 匯出", "de": "Claude.ai-Export importieren",
        "es": "Importar exportación de Claude.ai", "ja": "Claude.aiエクスポートをインポート",
        "ko": "Claude.ai 내보내기 가져오기", "ar": "استيراد تصدير Claude.ai",
        "zh-Hans": "导入 Claude.ai 导出", "ru": "Импорт экспорта Claude.ai",
        "pt-BR": "Importar exportação do Claude.ai", "hi": "Claude.ai एक्सपोर्ट आयात करें",
        "id": "Impor ekspor Claude.ai", "tr": "Claude.ai dışa aktarımını içe aktar",
        "bn": "Claude.ai এক্সপোর্ট আমদানি করুন", "th": "นำเข้าการส่งออก Claude.ai",
    },
    "hub.memory.settings.wipe": {
        "en": "Clear index", "fr": "Effacer l'index", "zh-Hant": "清除索引",
        "de": "Index löschen", "es": "Borrar índice", "ja": "インデックスを消去",
        "ko": "인덱스 지우기", "ar": "مسح الفهرس", "zh-Hans": "清除索引",
        "ru": "Очистить индекс", "pt-BR": "Limpar índice", "hi": "इंडेक्स साफ़ करें",
        "id": "Hapus indeks", "tr": "Dizini temizle", "bn": "ইনডেক্স মুছুন",
        "th": "ล้างดัชนี",
    },
    "hub.memory.settings.open-folder": {
        "en": "Open folder", "fr": "Ouvrir le dossier", "zh-Hant": "打開文件夾",
        "de": "Ordner öffnen", "es": "Abrir carpeta", "ja": "フォルダを開く",
        "ko": "폴더 열기", "ar": "افتح المجلد", "zh-Hans": "打开文件夹",
        "ru": "Открыть папку", "pt-BR": "Abrir pasta", "hi": "फ़ोल्डर खोलें",
        "id": "Buka folder", "tr": "Klasörü aç", "bn": "ফোল্ডার খুলুন",
        "th": "เปิดโฟลเดอร์",
    },
    "hub.memory.settings.no-index": {
        "en": "No index", "fr": "Pas d'index", "zh-Hant": "無索引", "de": "Kein Index",
        "es": "Sin índice", "ja": "インデックスなし", "ko": "인덱스 없음", "ar": "لا يوجد فهرس",
        "zh-Hans": "无索引", "ru": "Нет индекса", "pt-BR": "Sem índice", "hi": "कोई इंडेक्स नहीं",
        "id": "Tidak ada indeks", "tr": "Dizin yok", "bn": "কোনো ইনডেক্স নেই", "th": "ไม่มีดัชนี",
    },
    "hub.memory.settings.auto-indexed": {
        "en": "Indexed automatically", "fr": "Indexé automatiquement", "zh-Hant": "自動索引",
        "de": "Automatisch indexiert", "es": "Indexado automáticamente", "ja": "自動インデックス済み",
        "ko": "자동으로 인덱싱됨", "ar": "مُفهرَس تلقائياً", "zh-Hans": "自动索引",
        "ru": "Индексируется автоматически", "pt-BR": "Indexado automaticamente",
        "hi": "स्वचालित रूप से अनुक्रमित", "id": "Diindeks otomatis", "tr": "Otomatik olarak dizinlendi",
        "bn": "স্বয়ংক্রিয়ভাবে ইনডেক্স হয়েছে", "th": "จัดทำดัชนีอัตโนมัติ",
    },
    "hub.memory.settings.wipe.confirm-title": {
        "en": "Clear index?", "fr": "Effacer l'index ?", "zh-Hant": "清除索引？",
        "de": "Index löschen?", "es": "¿Borrar índice?", "ja": "インデックスを消去しますか？",
        "ko": "인덱스를 지울까요?", "ar": "مسح الفهرس؟", "zh-Hans": "清除索引？",
        "ru": "Очистить индекс?", "pt-BR": "Limpar índice?", "hi": "इंडेक्स साफ़ करें?",
        "id": "Hapus indeks?", "tr": "Dizini temizle?", "bn": "ইনডেক্স মুছবেন?",
        "th": "ล้างดัชนี?",
    },
    "hub.memory.settings.wipe.confirm-action": {
        "en": "Clear", "fr": "Effacer", "zh-Hant": "清除", "de": "Löschen",
        "es": "Borrar", "ja": "消去", "ko": "지우기", "ar": "مسح",
        "zh-Hans": "清除", "ru": "Очистить", "pt-BR": "Limpar", "hi": "साफ़ करें",
        "id": "Hapus", "tr": "Temizle", "bn": "মুছুন", "th": "ล้าง",
    },
    "hub.memory.settings.wipe.cancel": {
        "en": "Cancel", "fr": "Annuler", "zh-Hant": "取消", "de": "Abbrechen",
        "es": "Cancelar", "ja": "キャンセル", "ko": "취소", "ar": "إلغاء",
        "zh-Hans": "取消", "ru": "Отмена", "pt-BR": "Cancelar", "hi": "रद्द करें",
        "id": "Batal", "tr": "İptal", "bn": "বাতিল", "th": "ยกเลิก",
    },
    "hub.memory.settings.wipe.confirm-message": {
        "en": "This action is irreversible.", "fr": "Cette action est irréversible.",
        "zh-Hant": "此操作不可撤銷。", "de": "Diese Aktion ist unwiderruflich.",
        "es": "Esta acción es irreversible.", "ja": "この操作は元に戻せません。",
        "ko": "이 작업은 되돌릴 수 없습니다.", "ar": "هذا الإجراء لا يمكن التراجع عنه.",
        "zh-Hans": "此操作不可撤销。", "ru": "Это действие необратимо.",
        "pt-BR": "Esta ação é irreversível.", "hi": "यह क्रिया अपरिवर्तनीय है।",
        "id": "Tindakan ini tidak dapat dibatalkan.", "tr": "Bu işlem geri alınamaz.",
        "bn": "এই ক্রিয়া পূর্বাবস্থায় ফেরানো যাবে না।", "th": "การดำเนินการนี้ไม่สามารถย้อนกลับได้",
    },
    "hub.memory.show.resume.copied": {
        "en": "Copied!", "fr": "Copié !", "zh-Hant": "已複製！", "de": "Kopiert!",
        "es": "¡Copiado!", "ja": "コピーしました！", "ko": "복사됨!", "ar": "نُسخ!",
        "zh-Hans": "已复制！", "ru": "Скопировано!", "pt-BR": "Copiado!", "hi": "कॉपी हो गया!",
        "id": "Disalin!", "tr": "Kopyalandı!", "bn": "কপি হয়েছে!", "th": "คัดลอกแล้ว!",
    },
    "hub.memory.search.no-results": {
        "en": "No results", "fr": "Aucun résultat", "zh-Hant": "無結果", "de": "Keine Ergebnisse",
        "es": "Sin resultados", "ja": "結果なし", "ko": "결과 없음", "ar": "لا نتائج",
        "zh-Hans": "无结果", "ru": "Нет результатов", "pt-BR": "Sem resultados", "hi": "कोई परिणाम नहीं",
        "id": "Tidak ada hasil", "tr": "Sonuç yok", "bn": "কোনো ফলাফল নেই", "th": "ไม่มีผลลัพธ์",
    },
}


def make_entry(translations: dict) -> dict:
    localizations = {}
    for lang, value in translations.items():
        localizations[lang] = {
            "stringUnit": {
                "state": "translated",
                "value": value
            }
        }
    return {"localizations": localizations}


def main():
    path = XCSTRINGS
    if not path.exists():
        print(f"Error: {path} not found", file=sys.stderr)
        sys.exit(1)

    with open(path, encoding="utf-8") as f:
        data = json.load(f)

    strings = data.setdefault("strings", {})
    added = 0
    skipped = 0

    for key, translations in STRINGS.items():
        if key in strings:
            skipped += 1
            print(f"  skip (already exists): {key}")
        else:
            strings[key] = make_entry(translations)
            added += 1
            print(f"  add: {key}")

    # Sort keys for reproducibility
    data["strings"] = dict(sorted(data["strings"].items()))

    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
        f.write("\n")

    print(f"\nDone: {added} added, {skipped} skipped.")


if __name__ == "__main__":
    main()
