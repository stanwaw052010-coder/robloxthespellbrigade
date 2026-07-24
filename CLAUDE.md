# Magic Brigade — правила проекта

Кооперативный wave-defense на Roblox / Luau. Синхронизация в Studio через
Rojo. Подробности геймплея — в `README.md`, руководство по промптам —
в `docs/PROMPT_GUIDE.md`.

## Стек и команды

```bash
rokit install                      # rojo 7.5.1, stylua 2.0.2, luau-lsp 1.32.4
rojo serve                         # разработка: плагин Rojo в Studio
rojo build -o build.rbxl           # проверка: структура и синтаксис
stylua src                         # форматирование (--check в проверках)

# статический анализ (globalTypes.d.luau скачивается один раз)
rojo sourcemap default.project.json -o sourcemap.json
luau-lsp analyze --sourcemap=sourcemap.json --defs=globalTypes.d.luau \
  --base-luaurc=.luaurc src
```

Перед коммитом должны проходить: `rojo build`, `stylua --check src`,
`luau-lsp analyze` (0 ошибок).

## Структура

| Путь | Куда попадает | Содержимое |
|---|---|---|
| `src/Shared/` | `ReplicatedStorage.Shared` | конфиги, каталоги данных, `Remotes`, `Signal` |
| `src/Server/` | `ServerScriptService.Server` | `init.server.luau` + `Services/` |
| `src/Client/` | `StarterPlayerScripts.Client` | `init.client.luau` + контроллеры |

Сервисы и контроллеры экспортируют `Init()` и `Start()`; бутстрап вызывает
все `Init()`, затем все `Start()`. Данные (`SpellbookModule`,
`EnemyDefinitions`, `WaveDefinitions`, `UpgradeCatalogue`) — чистые таблицы
без побочных эффектов.

## Жёсткие правила

1. **Сервер — авторитет.** Клиент отправляет только намерение. Урон, HP,
   мана, кулдауны, валюта, дроп считаются на сервере. Каждый RemoteEvent
   валидирует: rate-limit (`AntiExploit`), владение способностью, кулдаун,
   ресурс, дистанцию с допуском на пинг.
2. **Урон только через `DamageService`.** Прямых изменений `Humanoid.Health`
   в других модулях быть не должно.
3. **Никаких внешних ассетов.** Выдуманные `rbxassetid://<число>` запрещены;
   всё строится процедурно. Плейсхолдер — `rbxassetid://0` с комментарием.
4. **Числа баланса — в `GameConfig`** (и в таблицах данных), не в логике.
5. **Современный API:** `task.wait/spawn/delay`, `TweenService`,
   `LinearVelocity`/`AlignPosition`, `Humanoid.Animator:LoadAnimation`,
   `Debris`, `ContextActionService`.
   Запрещено: `wait()`, `spawn()`, `delay()`, `Instance.new("X", parent)`,
   `:remove()`, `BodyVelocity`/`BodyPosition`/`BodyGyro`,
   `Humanoid:LoadAnimation`, `LoadLibrary`.
6. **Каждое `:Connect()` отписывается** при удалении объекта, выходе игрока
   или конце матча. `WaitForChild` на сервере — только с таймаутом.
7. **DataStore — внутри `pcall`** с ретраями; в Studio без API-доступа
   проект работает в сессионном режиме и не сыплет ошибками.
8. **Мобильные поддерживаются наравне с ПК:** у каждого действия есть
   экранная кнопка.
9. `--!strict` в новых модулях, типы на публичных функциях, потолок ~600
   строк на файл.

## Стиль

- Именование: `PascalCase` для модулей и типов, `camelCase` для локальных,
  `SCREAMING_CASE` для констант модуля.
- Комментарии — по делу и на русском, как в существующих файлах.
- Новый враг/заклинание/апгрейд добавляется данными в соответствующий
  каталог `Shared`, а не новым спецкодом в сервисах.

## Проверка результата

Статика не ловит рантайм. После изменений сказать пользователю, что именно
проверить в Studio: Play, Output пуст, персонаж на полу, действие работает,
Test → 2 Players для сетевой логики.
