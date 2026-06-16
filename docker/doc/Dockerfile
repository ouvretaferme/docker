FROM python:3.12

WORKDIR /app

RUN pip install --no-cache-dir click==8.2.1 mkdocs mkdocs-material mkdocs-awesome-pages-plugin watchdog plantuml-markdown

CMD ["mkdocs", "serve", "-a", "0.0.0.0:8000", "--dirtyreload"]
