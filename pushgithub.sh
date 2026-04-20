#!/usr/bin/env bash
set -Eeuo pipefail

REPO_URL="https://github.com/reikwei/PostgreSQL-Central-server.git"
DEFAULT_BRANCH="main"
GIT_USER_NAME="${GIT_USER_NAME:-Xin Xier}"
GIT_USER_EMAIL="${GIT_USER_EMAIL:-host2ez@qq.com}"
PROXY_HOST="192.168.50.101"
PROXY_PORT="7890"
PROXY_URL="http://${PROXY_HOST}:${PROXY_PORT}"
COMMIT_MESSAGE="${1:-chore: sync PostgreSQL Central Server}"

cleanup() {
  unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY all_proxy
}

log() {
  echo "[pushgithub] $*"
}

die() {
  echo "[pushgithub][error] $*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "缺少命令: $1"
}

trap cleanup EXIT

require_command git

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
cd "${SCRIPT_DIR}"

log "准备启用临时代理 ${PROXY_URL}"
export http_proxy="${PROXY_URL}"
export https_proxy="${PROXY_URL}"
export HTTP_PROXY="${PROXY_URL}"
export HTTPS_PROXY="${PROXY_URL}"
export ALL_PROXY="${PROXY_URL}"
export all_proxy="${PROXY_URL}"

if [[ ! -d .git ]]; then
  log "当前目录不是 git 仓库，正在初始化"
  git init
fi

git config user.name "${GIT_USER_NAME}"
git config user.email "${GIT_USER_EMAIL}"

if git remote get-url origin >/dev/null 2>&1; then
  log "更新 origin 到 ${REPO_URL}"
  git remote set-url origin "${REPO_URL}"
else
  log "添加 origin ${REPO_URL}"
  git remote add origin "${REPO_URL}"
fi

git checkout -B "${DEFAULT_BRANCH}"

REMOTE_BRANCH_EXISTS=false
if git ls-remote --exit-code --heads origin "${DEFAULT_BRANCH}" >/dev/null 2>&1; then
  REMOTE_BRANCH_EXISTS=true
  log "检测到远端 ${DEFAULT_BRANCH} 分支，正在抓取"
  git fetch origin "${DEFAULT_BRANCH}"
fi

git add -A

if git diff --cached --quiet; then
  log "没有可提交的变更，继续执行 push"
else
  log "创建提交: ${COMMIT_MESSAGE}"
  git commit -m "${COMMIT_MESSAGE}"
fi

if ${REMOTE_BRANCH_EXISTS}; then
  if git rev-parse --verify HEAD >/dev/null 2>&1; then
    if git merge-base --is-ancestor "origin/${DEFAULT_BRANCH}" HEAD >/dev/null 2>&1; then
      log "本地已包含远端 ${DEFAULT_BRANCH} 历史"
    else
      log "合并远端 ${DEFAULT_BRANCH} 历史"
      git merge --no-edit --allow-unrelated-histories "origin/${DEFAULT_BRANCH}"
    fi
  else
    log "本地尚无提交，切换到远端 ${DEFAULT_BRANCH}"
    git checkout -B "${DEFAULT_BRANCH}" "origin/${DEFAULT_BRANCH}"
  fi
fi

log "推送到 origin/${DEFAULT_BRANCH}"
git push -u origin "${DEFAULT_BRANCH}"

log "推送完成，临时代理已清理"