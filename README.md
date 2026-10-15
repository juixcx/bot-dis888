# JUIX Forge Obfuscator Bot

VM-based Lua obfuscator as a Discord bot.

## Setup

### 1. Clone repo
\`\`\`bash
git clone https://github.com/USERNAME/juix-obf-bot.git
cd juix-obf-bot
\`\`\`

### 2. Install dependencies
\`\`\`bash
npm install
\`\`\`

### 3. Create `.env`
\`\`\`bash
cp .env.example .env
nano .env
\`\`\`

Fill in:
- `DISCORD_TOKEN` — from Discord Developer Portal
- `GUILD_ID` (optional) — for instant slash commands

### 4. Run
\`\`\`bash
node bot.js
\`\`\`

### 5. 24/7 (Termux)
\`\`\`bash
pkg install tmux
tmux new -s juixbot
node bot.js
# Ctrl+B then D to detach
\`\`\`

## Commands
- `/obf` — upload `.lua` file
- `/obftext` — paste source
- `/reload` — reload `obf.lua` from disk
- `/help` — usage

## Updating obfuscator
1. Edit `obf.lua` in repo
2. Commit
3. `git pull` in Termux
4. `/reload` in Discord

Made by discord.gg/kurokoai
