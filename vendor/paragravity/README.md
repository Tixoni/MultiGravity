# ParaGravity (pgrav)

Консольная утилита, через которую MultiGravity создаёт, запускает и удаляет изолированные профили Antigravity.

- Источник: [edison-land/paragravity](https://github.com/edison-land/paragravity), версия `1.2.0`, коммит `d553e18`.
- Лицензия: MIT, текст в [`LICENSE`](LICENSE). Код не изменён.
- В репозиторий взяты только файлы, нужные на Windows: `paragravity` (сам скрипт) и обёртки `pgrav.cmd` / `paragravity.cmd`.
  Веб-консоль (`pgrav web`) и виджет для macOS сюда не входят.

Утилите нужен только Python 3 из стандартной поставки — сторонние пакеты не требуются.

Запуск из консоли из корня репозитория:

```bat
vendor\paragravity\pgrav.cmd list
vendor\paragravity\pgrav.cmd create work --links minimal --launch
```
