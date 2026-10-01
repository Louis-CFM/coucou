# Codex masaüstü: doğrulanmış yetenekler ve kontrol sınırı

Tarih: 2026-10-01.

Bu not mevcut Windows makinesindeki doğrulamayı kaydeder. Masaüstü uygulaması 26.928.2636.0; uygulamanın başlattığı Codex CLI çalışma zamanı 0.159.2. PATH üzerindeki npm CLI 0.159.3 olduğundan, masaüstü uyumluluğu npm sürümüne göre varsayılmamalıdır. Uygulama çalışma zamanında `hooks` özelliği `stable` ve açık durumdadır.

## Canlı hook kanıtı

Gerçek masaüstü sohbetinde, daha önce kurulmuş ve güvenilmiş kullanıcı hook'ları Coucou'nun yerel uygulamasına ulaştı. Canlı kanıt `PreToolUse` ve `PostToolUse` olaylarını Bash ve MCP araçları için içeriyordu; kontrol yalnızca Codex sağlayıcısı, oturum/tur kimlikleri ve olay türü gibi metadata kullandı. Deneme mevcut kurulumla yapıldı; kullanıcı hook yapılandırması değiştirilmedi.

Bu, Codex masaüstü sohbetlerinin etkin yerel runtime'da lifecycle hook'ları çalıştırabildiğini ve Coucou'nun olayları yerel olarak gösterebildiğini doğrular. Hook'lar sohbet açma, yeni mesaj gönderme veya aktif turu kesme komutları değildir. Yeni ya da değişmiş bir hook tanımı içerik hash'iyle yeniden incelenip güvenilene kadar çalışmaz; `/hooks` inceleme ve güven verme için belgelenmiş arayüzdür. Trust kontrolünü atlayan `--dangerously-bypass-hook-trust` üretim akışında kullanılmamalıdır.

## Mevcut sohbetleri kontrol etme

Bu makinede `codex app-server daemon version` mevcut daemon'a bağlanamadı ve `app-server proxy` için gereken kontrol soketi erişilebilir değildi. Bu nedenle Coucou'nun mevcut masaüstü sohbetlerine bağlanabileceği bir app-server kanalı doğrulanmadı. `codex app-server` ile ayrı bir sunucu başlatmak kendi runtime'ını oluşturur; bu, masaüstünde açık olan sohbetin runtime'ına bağlanmak anlamına gelmez.

Resmî app-server protokolü bağlı olduğu sunucuya ait thread'leri listeleyip okuyabilir, devam ettirebilir ve `turn/steer` ile `turn/interrupt` çağrılarını destekler. Belgeler, bu protokolün etkin ChatGPT masaüstü sohbetlerinin runtime'ına bağlandığını söylemiyor. Ayrıca Codex uygulamasının bu konuşmada sunduğu thread gezinme/gönderim araçları Coucou executable'ına açık bir dış API sağlamaz; bu araç yüzeyinde ayrı bir kesinti komutu da yoktur.

Codex masaüstü ve CLI, yapılandırılmış MCP sunucularını paylaşır. Bu, Codex'in Coucou'nun sunduğu MCP araçlarını çağırmasını sağlar; Coucou'ya Codex'in açık sohbetlerini yönetme yetkisi vermez. İç uygulama araçları için ortama enjekte edilen pipe değişkeni belgelenmiş bir genel kontrol protokolü olarak sunulmadığından entegrasyon sözleşmesi yapılmamalıdır.

| Yetkinlik | Mevcut kanıt |
| --- | --- |
| Yerel Codex masaüstü sohbetinden hook olayı alma | Doğrulandı: gerçek Bash ve MCP araçları için `PreToolUse` ve `PostToolUse` |
| Exact thread'i uygulama içinden açma veya mesaj gönderme | Codex uygulama araç yüzeyi mevcut; Coucou'nun bu yüzeye erişimi doğrulanmadı |
| Coucou'dan mevcut thread'e devam mesajı gönderme | Desteklenen dış kanal doğrulanmadı |
| Coucou'dan mevcut thread'i kesme | Desteklenen dış kanal doğrulanmadı |

İlk canlı entegrasyon hook tabanlı izleme ve hook'un desteklediği onay akışıyla sınırlı tutulmalıdır. Aynı sohbete devam mesajı veya kesinti, kullanılabilir ve yetkilendirilmiş bir uygulama kontrol kanalı ayrıca doğrulanana kadar masaüstü uygulamasından yapılır.

## Uygulama ve gerçek test sonucu

Windows entegrasyonu `codex/desktop-live-integration` dalında uygulandı. Canlı oturum kartları ilk yerel sohbeti otomatik odaklar; diğer sohbetler erişilebilir kaydırmalı listede kalır. Eski tur olayları yeni turu geri alamaz; kesilmiş veya tamamlanmış tur geç gelen araç olaylarıyla tekrar çalışıyor durumuna dönmez. Uzun oturumlarda son işlem satırı güncellenir. İzin kapanışı sağlayıcı, oturum, tur ve istek kimliğiyle eşleşir; bağlantı kopması ve zaman aşımı kartı temizler.

2026-10-01 gerçek testleri:

- Derlenmiş Windows Coucou üzerinde mevcut Codex masaüstü sohbetleri ve Luna alt ajanlarından gelen gerçek hook'lar gözlendi. Dört ayrı oturum, `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `Stop`, `PermissionRequest` ve `PermissionRequestClosed` görüldü. Özel sohbet gövdeleri veya araç içerikleri kanıt dosyasına kaydedilmedi.
- `windows/scripts/verify-codex-runtime-hooks.mjs` kurulu masaüstü CLI **0.159.2** ve gerçek **gpt-6-luna** modelini ayrı, geçici app-server ile çalıştırdı. Coucou **Allow**: işaret dosyası oluştu; **Deny**: oluşmadı; iki tur da başarılı kapandı. Coucou kapalı: bir native onay fallback'i geldi, reddedildi ve tur kapandı. Üç denemenin temizliği de tamamlandı, çıkış kodu 0.
- Bu izin denemeleri kurulu runtime'ın gerçek hook/komut akışını doğrular; açık masaüstü sohbetine dışarıdan bağlanma kanıtı değildir. Bu mevcut sohbetin onay politikası `never` olduğundan onun içinden insan onayı senaryosu üretilmedi.
- Rust workspace testleri: 59 başarılı; iki manuel canlı testi ignored. TypeScript/Vite ve Tauri/NSIS paketlemesi başarılı. Frontend testleri: 33 başarılı. Eski tur, kesinti, paralel oturum, izin kapanışı ve uzun işlem geçmişi regresyonlarını kapsar.

Hook tanımları ve güven durumu bu doğrulama sırasında değiştirilmedi. Deneme uygulaması geçici profil kullandı; kullanıcının kurulu Coucou sürümü otomatik değiştirilmedi.

## Kaynaklar

- [Codex hooks](https://learn.chatgpt.com/docs/hooks): hook kaynakları, olaylar, trust incelemesi ve araç kapsamı.
- [Codex app-server](https://learn.chatgpt.com/docs/app-server): JSON-RPC protokolü, thread işlemleri ve app-server bağlantıları.
- [Codex MCP](https://learn.chatgpt.com/docs/extend/mcp): masaüstü ve CLI'da MCP sunucusu desteği ve yapılandırma paylaşımı.
