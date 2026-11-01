#!/bin/bash
echo "🔍 CI: проверка на TODO в Python файлах..."

# Ищем TODO во всех Python файлах проекта (исключая .git, venv, node_modules, build)
TODO_FILES=$(find . -name "*.py" | \
             grep -v node_modules | grep -v build | grep -v .git | grep -v venv | grep -v __pycache__ | \
             xargs grep -l "TODO" 2>/dev/null || true)

if [ -n "$TODO_FILES" ]; then
    echo "❌ CI failed: TODO found in codebase"
    echo "Файлы с TODO:"
    echo "$TODO_FILES"
    exit 1
fi

echo "✅ CI passed: TODO не найдены"
exit 0
