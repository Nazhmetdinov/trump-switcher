import Foundation

/// Locally authored, complete spellings. These lists supplement Hunspell; they
/// do not generate suffixes, accept arbitrary names, or learn from user input.
/// Keep categories enumerable so every entry can be checked against both
/// physical layouts and against already valid source words before release.
public enum ReviewedVocabulary {
    private static func words(_ value: String) -> Set<String> {
        Set(value.split(whereSeparator: \.isWhitespace).map(String.init))
    }

    public static let russianNames = words("""
    артём артёма артёму артёмом артёме артем артема артему артемом артеме
    артемий артемия артемию артемием артемии
    артур артура артуру артуром артуре
    антон антона антону антоном антоне борис бориса борису борисом борисе
    вадим вадима вадиму вадимом вадиме валерий валерия валерию валерием валерии
    василий василия василию василием василии виктор виктора виктору виктором викторе
    виталий виталия виталию виталием виталии владимир владимира владимиру владимиром владимире
    владислав владислава владиславу владиславом владиславе вячеслав вячеслава вячеславу вячеславом вячеславе
    георгий георгия георгию георгием георгии глеб глеба глебу глебом глебе
    григорий григория григорию григорием григории данил данила данилу данилом даниле
    даниил даниила даниилу даниилом данииле денис дениса денису денисом денисе
    евгений евгения евгению евгением евгении егор егора егору егором егоре
    иван ивана ивану иваном иване илья ильи илье илью ильёй ильей
    кирилл кирилла кириллу кириллом кирилле константин константина константину константином константине
    лев льва льву львом льве леонид леонида леониду леонидом леониде
    максим максима максиму максимом максиме матвей матвея матвею матвеем матвее
    никита никиты никите никиту никитой олег олега олегу олегом олеге
    павел павла павлу павлом павле пётр петра петру петром петре петр
    роман романа роману романом романе руслан руслана руслану русланом руслане
    станислав станислава станиславу станиславом станиславе степан степана степану степаном степане
    тимофей тимофея тимофею тимофеем тимофее тимур тимура тимуру тимуром тимуре
    фёдор фёдора фёдору фёдором фёдоре федор федора федору федором федоре
    юрий юрия юрию юрием юрии ярослав ярослава ярославу ярославом ярославе
    агата агаты агате агату агатой алёна алёны алёне алёну алёной алена алены алене алену аленой
    алина алины алине алину алиной алиса алисы алисе алису алисой
    анна анны анне анну анной арина арины арине арину ариной
    валентина валентины валентине валентину валентиной валерия валерии валерию валерией
    варвара варвары варваре варвару варварой вера веры вере веру верой
    вероника вероники веронике веронику вероникой виктория виктории викторию викторией
    галина галины галине галину галиной дарья дарьи дарье дарью дарьей
    диана дианы диане диану дианой евгения евгении евгению евгенией
    елена елены елене елену еленой елизавета елизаветы елизавете елизавету елизаветой
    жанна жанны жанне жанну жанной зоя зои зое зою зоей
    инна инны инне инну инной ирина ирины ирине ирину ириной
    карина карины карине карину кариной кира киры кире киру кирой
    кристина кристины кристине кристину кристиной ксения ксении ксению ксенией
    лариса ларисы ларисе ларису ларисой любовь любви любовью людмила людмилы людмиле людмилу людмилой
    маргарита маргариты маргарите маргариту маргаритой марина марины марине марину мариной
    мария марии марию марией надежда надежды надежде надежду надеждой
    оксана оксаны оксане оксану оксаной полина полины полине полину полиной
    светлана светланы светлане светлану светланой софия софии софию софией
    софья софьи софье софью софьей таисия таисии таисию таисией
    тамара тамары тамаре тамару тамарой татьяна татьяны татьяне татьяну татьяной
    ульяна ульяны ульяне ульяну ульяной юлия юлии юлию юлией яна яны яне яну яной
    александрович александровича александровичу александровичем александровиче
    александровна александровны александровне александровну александровной
    алексеевич алексеевича алексеевичу алексеевичем алексеевиче
    алексеевна алексеевны алексеевне алексеевну алексеевной
    андреевич андреевича андреевичу андреевичем андреевиче
    андреевна андреевны андреевне андреевну андреевной
    дмитриевич дмитриевича дмитриевичу дмитриевичем дмитриевиче
    дмитриевна дмитриевны дмитриевне дмитриевну дмитриевной
    игоревич игоревича игоревичу игоревичем игоревиче
    игоревна игоревны игоревне игоревну игоревной
    сергеевич сергеевича сергеевичу сергеевичем сергеевиче
    сергеевна сергеевны сергеевне сергеевну сергеевной
    иванов иванова иванову ивановым иванове ивановой ивановы ивановых
    петров петрова петрову петровым петрове петровой петровы петровых
    сидоров сидорова сидорову сидоровым сидорове сидоровой сидоровы сидоровых
    смирнов смирнова смирнову смирновым смирнове смирновой смирновы смирновых
    кузнецов кузнецова кузнецову кузнецовым кузнецове кузнецовой кузнецовы кузнецовых
    попов попова попову поповым попове поповой поповы поповых
    соколов соколова соколову соколовым соколове соколовой соколовы соколовых
    новиков новикова новикову новиковым новикове новиковой новиковы новиковых
    фёдоров фёдорова фёдорову фёдоровым фёдорове фёдоровой федоров федорова федорову федоровым федорове федоровой
    джон джона джону джоном джоне майкл майкла майклу майклом майкле
    джеймс джеймса джеймсу джеймсом джеймсе роберт роберта роберту робертом роберте
    эмили эмма оливия софия джессика
    """)

    public static let englishNames = words("""
    alex alexander alexandra alexey alexei anastasia andrew anna anthony anton artem arthur
    benjamin boris brian charles charlotte chloe christopher daniel david denis diana dimitri dmitri dmitry
    edward elena elizabeth emily emma eric ethan evan evgeny george gregory hannah harry henry
    igor irina isabella ivan jack jacob james jason jennifer jessica john jonathan joseph joshua julia justin
    kate katherine kevin kirill laura leon leo liam lily linda lucas luke maria mark martin matthew
    maxim michael michelle natalia natalie nathan nicholas nikita nikolai noah olga oliver olivia
    oscar owen patrick paul peter philip rachel rebecca richard robert roman ryan samuel sarah
    sergey sergei sophia stanislav stephen steven susan tatiana thomas timothy tyler victor viktor
    vladimir william yulia yuri zachary zoe
    adams allen anderson baker brown campbell carter clark collins cooper davis edwards evans
    garcia green harris hill jackson johnson jones king lewis martin miller mitchell moore morgan
    morris nelson parker phillips richardson roberts robinson scott smith taylor thompson turner
    walker watson white williams wilson wright young
    mcdonald mckenzie mccarthy mcgregor macdonald o'connor o'brien o'neill d'angelo
    """)

    public static let russianBrands = words("""
    телемост телемоста телемосту телемостом телемосте
    вконтакте вотсап вотсапа вотсапу вотсапом вотсапе
    ватсапп ватсаппа ватсаппу ватсаппом ватсаппе
    тикток тиктока тиктоку тиктоком тиктоке
    скайп скайпа скайпу скайпом скайпе
    слак слака слаку слаком слаке
    ноушен обсидиан обсидиана обсидиану обсидианом обсидиане
    трелло миро канва зед зеро чери джили хавал
    спотифай нетфликс бусти патреон кинопоиск кинопоиска кинопоиску кинопоиском кинопоиске
    самокат самоката самокату самокатом самокате вкусвилл вкусвилла вкусвиллу вкусвиллом вкусвилле
    пятёрочка пятёрочки пятёрочке пятёрочку пятёрочкой пятерочка пятерочки пятерочке пятерочку пятерочкой
    перекрёсток перекрёстка перекрёстку перекрёстком перекрёстке перекресток перекрестка перекрестку перекрестком перекрестке
    мегамаркет мегамаркета мегамаркету мегамаркетом мегамаркете
    ламода ламоды ламоде ламоду ламодой детмир детмира детмиру детмиром детмире
    альфа альфы альфе альфу альфой альфабанк альфабанка альфабанку альфабанком альфабанке
    райффайзен райффайзена райффайзену райффайзеном райффайзене
    росбанк росбанка росбанку росбанком росбанке
    ростелеком ростелекома ростелекому ростелекомом ростелекоме
    мегафон мегафона мегафону мегафоном мегафоне билайн билайна билайну билайном билайне
    тбанк тбанка тбанку тбанком тбанке
    озонбанк озонбанка озонбанку озонбанком озонбанке
    самсунг самсунга самсунгу самсунгом самсунге сяоми хуавей хонор
    асус леново эйсер делл логитек рапоо
    плейстейшен плейстейшн иксбокс нинтендо стим стима стиму стимом стиме
    адоб фотошоп фотошопа фотошопу фотошопом фотошопе иллюстратор иллюстратора иллюстраторе
    блендер блендера блендеру блендером блендере скетч скетча скетчу скетчем скетче
    питон питона питону питоном питоне джава джавы джаве джаву джавой котлин раст
    джейсон гитлаб гитлаба гитлабу гитлабом гитлабе
    редис постгрес постгреса постгресу постгресом постгресе
    кубернетес кубернетеса кубернетесу кубернетесом кубернетесе
    ансибл терраформ графана прометеус дженкинс
    опенаи антропик гемини олама оллама локалхост вебкит
    """)

    public static let englishBrands = words("""
    samsung xiaomi huawei honor lenovo asus acer dell logitech rapoo razer
    nvidia radeon geforce qualcomm snapdragon mediatek broadcom realtek
    playstation xbox nintendo steam epicgames ubisoft minecraft roblox fortnite
    adobe photoshop illustrator indesign lightroom premiere aftereffects blender sketch affinity
    canva miro trello asana clickup airtable monday basecamp todoist ticktick
    linear sentry datadog grafana prometheus jenkins ansible terraform pulumi
    digitalocean hetzner linode vultr supabase firebase planetscale neon netlify render
    huggingface replicate together groq cerebras mistral qwen llama gemma comfyui
    wechat wecom signal viber snapchat twitch patreon boosty substack medium tumblr
    telemost salutespeak ruviki dzen habr pikabu banki superjob rabota
    aliexpress alibaba temu shein amazon ebay paypal stripe shopify woocommerce
    booking airbnb agoda trivago expedia tripadvisor uber lyft bolt grab
    revolut wise payoneer alfabank raiffeisen rosbank gazprombank megafon beeline rostelecom tbank
    lamoda detmir vkusvill perekrestok pyaterochka megamarket samokat
    zoominfo zendesk intercom freshdesk salesforce hubspot mailchimp brevo sendgrid
    fastmail tutanota tutamail tailscale zerotier wireguard openvpn nextcloud syncthing
    parallels vmware virtualbox utm crossover rosetta ventura sonoma sequoia tahoe
    handbrake vlc obs ffmpeg imagemagick audacity davinci resolve capcut filmora
    jetbrains rider resharper goland rustrover datagrip fleet zed neovim vscode vscodium
    rustup cargo golang nodejs deno bun npm pnpm yarn esbuild rollup webpack turbopack
    svelte sveltekit nuxt vue angular solidjs preact astro tailwind bootstrap storybook
    playwright vitest pytest jest mocha cypress selenium puppeteer electron tauri
    flask django fastapi pydantic sqlalchemy alembic celery rabbitmq kafka clickhouse elasticsearch
    opensearch duckdb mariadb dynamodb snowflake bigquery redshift timescale prisma drizzle
    jupyter numpy pandas scipy pytorch tensorflow keras scikit seaborn plotly matplotlib
    """)

    public static let russianColloquial = words("""
    краш краша крашу крашем краше краши крашей крашить крашится крашился крашилась крашились
    кринж кринжа кринжу кринжем кринже кринжовый кринжовая кринжовое кринжовые
    рофл рофла рофлу рофлом рофле рофлы рофлов рофлить рофлю рофлишь рофлит
    имхо плиз плз спс сорян сорри лол кек жиза лан щас ваще чёт чёто чето
    чел чела челу челом челе челы челов
    норм нормас нормальный нормальная нормальное нормальные
    токсик токсика токсику токсиком токсике токсики токсиков токсичный токсичная
    хейт хейта хейту хейтом хейте хейтер хейтера хейтеру хейтером хейтере хейтеры хейтеров
    хайп хайпа хайпу хайпом хайпе хайповый хайповая хайповые хайпить
    чил чила чилу чилом чиле чилить чиллю чиллишь чиллит чиллим чиллил чиллила чиллили
    кайф кайфа кайфу кайфом кайфе кайфово кайфовый кайфовая
    изи погнали харош хорош хороши
    пруф пруфа пруфу пруфом пруфе пруфы пруфов пруфами
    инсайт инсайта инсайту инсайтом инсайте инсайты инсайтов
    баг бага багу багом баге багов багам багами багах багфикс багфикса багфиксы
    фикс фикса фиксу фиксом фиксе фиксы фиксов фиксить фикшу фиксишь фиксит фиксим фиксите фиксят фиксил фиксила фиксили
    пофиксить пофиксил пофиксила пофиксили пофикшено
    релиз релиза релизу релизом релизе релизы релизов релизить зарелизить зарелизил
    апдейта апдейту апдейтом апдейте апдейты апдейтов апдейтить апдейтнул апдейтнули
    даунгрейд даунгрейда даунгрейду даунгрейдом даунгрейде
    лог логов логам логами логах логировать логирование логирования логированию
    репродьюс репродьюса воспроизводится воспроизвелось воспроизвёлось
    скрин скрина скрину скрином скрине скрины скринов скринам скринами скринах
    скринить скриню скринишь скринит заскринил заскринила заскринили
    скролл скролла скроллу скроллом скролле скроллить скроллю скроллишь скроллим
    тап тапа тапу тапом тапе тапы тапов тапнуть тапни тапните
    свайпа свайпу свайпом свайпе свайпы свайпов свайпнул свайпнула свайпнули
    лайка лайку лайком лайке лайки лайков лайкнуть лайкнул лайкнула лайкнули
    дизлайк дизлайку дизлайком дизлайке дизлайки дизлайков
    репост репоста репосту репостом репосте репосты репостов репостнуть репостнул репостнули
    сторис рилса рилсу рилсом рилсе рилсы рилсов шортс шортса шортсы шортсов
    лонгрид лонгрида лонгриду лонгридом лонгриде лонгриды лонгридов
    подкаст подкаста подкасту подкастом подкасте подкасты подкастов подкастами
    чеклист чеклиста чеклисту чеклистом чеклисте чеклисты чеклистов
    таск таска таску таском таске таски тасков таскам тасками тасках тасочка тасочки
    таскать таскаю таскаешь
    синк синка синку синком синке синки синков засинкать засинкались синканём синканем
    дейлик дейлика дейлику дейликом дейлике дейлики дейликов
    мит митинг митинга митингу митингом митинге митинги митингов
    ретро ретроспектива ретроспективы ретроспективе ретроспективу ретроспективой
    бэклог бэклога бэклогу бэклогом бэклоге бэклоги бэклогов беклог беклога беклоге
    спринт спринта спринту спринтом спринте спринты спринтов
    ревью ревьюер ревьюера ревьюеру ревьюером ревьюере ревьюеры ревьюеров ревьюить
    поревьюить отревьюить отревьюил отревьюила отревьюили
    созвонов созвонам созвонами созвонах созвониться созвонимся созвонились
    дедлайнам дедлайнами дедлайнах дедлайнов
    деплоить деплою деплоишь деплоит деплоим деплоите деплоят деплоил деплоила деплоили задеплоить задеплоил задеплоила задеплоили
    коммитить коммичу коммитишь коммитит коммитим коммитите коммитят коммитил коммитила коммитили закоммитить закоммитил закоммитили
    пушить пушу пушишь пушит пушим пушите пушат пушил пушила пушили запушить запушил запушили
    форк форка форку форком форке форки форков форкнуть форкнул форкнули
    ребейз ребейза ребейзу ребейзом ребейзе ребейзы ребейзить заребейзить
    бранч бранча бранчу бранчем бранче бранчи бранчей
    нейронка нейронки нейронке нейронку нейронок нейронкам нейронках
    галлюцинация галлюцинации галлюцинаций галлюцинациями
    вайба вайбу вайбом вайбе вайбкодинга вайбкодингу вайбкодингом вайбкодинге
    вайбкодить вайбкодер вайбкодера вайбкодеру вайбкодером вайбкодере вайбкодеры вайбкодеров
    """)

    public static let englishColloquial = words("""
    lol lmao rofl brb btw imho tbh fyi asap afaik idk irl tldr
    cringe cringey cringeworthy chill chilling chillin vibes vibing lowkey highkey
    doomscroll doomscrolling meme memes memeing repost reposts reposted reblog reblogs
    livestream livestreams livestreaming livestreamer livestreamers vlog vlogs vlogger vloggers
    podcast podcasts podcaster podcasters reel reels shorts screenshotting screenrecord screencapture
    emoji emojis emote emotes reaction reactions unmute unmuted mute muted
    unfollow unfollowed unfollows unfriended unfriend unfriending
    downvote downvotes downvoted upvote upvotes upvoted clickbait ragebait deepfake deepfakes
    scammer scammers scammy phishing smishing vishing cybercrime cybersecurity
    bugfixes hotfix hotfixes changelog changelogs readme todo todos backlog backlogs
    codebase codebases monorepo monorepos polyrepo polyrepos refactor refactored refactoring
    linter linters linting typecheck typechecks typechecking autofix autofixes formatter formatters
    async await debuggable observability telemetry retry retries backoff deadlock deadlocks
    webhook's worktrees worktree's realtime runtime runtimes middleware microservice microservices
    deploy deploys deployed deploying redeploy redeployed redeploying rollback rollbacks
    signup signups onboarding offboarding standup standups retro retros sprint sprints
    freelancing freelancer freelancers coworking coworker coworkers upskill upskilling reskill reskilling
    solopreneur solopreneurs indiehacker indiehackers nocode lowcode opensource selfhosted
    livestreamed overengineered overengineering underengineered
    """)

    public static func names(_ layout: Layout) -> Set<String> {
        layout == .russian ? russianProper : englishProper
    }
    public static func colloquial(_ layout: Layout) -> Set<String> {
        layout == .russian ? russianColloquial : englishColloquial
    }
    // Build unions once; never allocate them per key/recognition decision.
    private static let russianProper = russianNames.union(russianBrands)
    private static let englishProper = englishNames.union(englishBrands)
    public static func recognizesName(_ word: String, _ layout: Layout) -> Bool {
        (layout == .russian ? russianProper : englishProper).contains(word)
    }
    public static func recognizesColloquial(_ word: String, _ layout: Layout) -> Bool {
        (layout == .russian ? russianColloquial : englishColloquial).contains(word)
    }
}
