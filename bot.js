// bot.js | JUIX Forge Obfuscator Bot
// Loads obf.lua from the same repo — no external fetch needed
require('dotenv').config();
const fs = require('fs');
const path = require('path');
const { Client, GatewayIntentBits, AttachmentBuilder, REST, Routes,
        SlashCommandBuilder, EmbedBuilder } = require('discord.js');
const { lua, lauxlib, lualib, to_luastring, to_jsstring } = require('fengari');

const TOKEN = process.env.DISCORD_TOKEN;
const GUILD_ID = process.env.GUILD_ID;
const MAX_SIZE = parseInt(process.env.MAX_FILE_SIZE || '1048576', 10);
const OBF_PATH = path.join(__dirname, 'obf.lua');

let OBF_SOURCE = null;

function loadObfuscator(force) {
    if (OBF_SOURCE && !force) return OBF_SOURCE;
    if (!fs.existsSync(OBF_PATH)) throw new Error('obf.lua not found at ' + OBF_PATH);
    OBF_SOURCE = fs.readFileSync(OBF_PATH, 'utf8');
    console.log(`[JUIX Bot] Obfuscator loaded (${OBF_SOURCE.length} bytes)`);
    return OBF_SOURCE;
}

function obfuscate(luaSource) {
    const obfSource = loadObfuscator(false);
    const L = lauxlib.luaL_newstate();
    lualib.luaL_openlibs(L);

    if (lauxlib.luaL_dostring(L, to_luastring(obfSource)) !== lua.LUA_OK) {
        const err = to_jsstring(lua.lua_tostring(L, -1));
        lua.lua_close(L);
        throw new Error('Obf load: ' + err);
    }

    lua.lua_pushstring(L, to_luastring(luaSource));
    lua.lua_setglobal(L, to_luastring('JUIX_INPUT'));

    const WRAPPER = 'JUIX_OUTPUT = OBF.obfuscate(JUIX_INPUT)';
    if (lauxlib.luaL_dostring(L, to_luastring(WRAPPER)) !== lua.LUA_OK) {
        const err = to_jsstring(lua.lua_tostring(L, -1));
        lua.lua_close(L);
        throw new Error('Obf run: ' + err);
    }

    lua.lua_getglobal(L, to_luastring('JUIX_OUTPUT'));
    const result = to_jsstring(lua.lua_tostring(L, -1));
    lua.lua_close(L);
    return result;
}

const client = new Client({
    intents: [GatewayIntentBits.Guilds, GatewayIntentBits.GuildMessages],
});

const commands = [
    new SlashCommandBuilder()
        .setName('obf')
        .setDescription('Obfuscate a Lua file with JUIX Forge')
        .addAttachmentOption(o => o.setName('file')
            .setDescription('The .lua file').setRequired(true)).toJSON(),
    new SlashCommandBuilder()
        .setName('obftext')
        .setDescription('Obfuscate Lua source as text')
        .addStringOption(o => o.setName('source')
            .setDescription('Lua source code').setRequired(true)).toJSON(),
    new SlashCommandBuilder()
        .setName('reload')
        .setDescription('Reload obfuscator from local file').toJSON(),
    new SlashCommandBuilder()
        .setName('help')
        .setDescription('How to use JUIX Forge Bot').toJSON(),
];

client.once('ready', async () => {
    console.log(`[JUIX Bot] Logged in as ${client.user.tag}`);
    try { loadObfuscator(false); }
    catch (e) { console.error('[JUIX Bot] Preload failed:', e.message); }

    const rest = new REST({ version: '10' }).setToken(TOKEN);
    try {
        if (GUILD_ID) {
            await rest.put(Routes.applicationGuildCommands(client.user.id, GUILD_ID),
                { body: commands });
            console.log(`[JUIX Bot] Guild commands registered (guild ${GUILD_ID})`);
        } else {
            await rest.put(Routes.applicationCommands(client.user.id),
                { body: commands });
            console.log('[JUIX Bot] Global commands registered (~1h to propagate)');
        }
    } catch (e) { console.error('[JUIX Bot] Command register failed:', e); }
});

client.on('interactionCreate', async (interaction) => {
    if (!interaction.isChatInputCommand()) return;
    const { commandName } = interaction;

    if (commandName === 'help') {
        const embed = new EmbedBuilder()
            .setTitle('JUIX Forge Obfuscator')
            .setColor(0x00FFAA)
            .setDescription('VM-based Lua obfuscator.')
            .addFields(
                { name: '/obf', value: 'Attach `.lua` → get obfuscated file' },
                { name: '/obftext', value: 'Paste source → get obfuscated file' },
                { name: '/reload', value: 'Reload obfuscator file' },
            )
            .setFooter({ text: 'JUIX Forge · discord.gg/kurokoai' })
            .setTimestamp();
        return interaction.reply({ embeds: [embed] });
    }

    if (commandName === 'reload') {
        await interaction.deferReply({ ephemeral: true });
        try {
            loadObfuscator(true);
            return interaction.editReply({ content: `Reloaded (${OBF_SOURCE.length} bytes)` });
        } catch (e) {
            return interaction.editReply({ content: 'Failed: ' + e.message });
        }
    }

    if (commandName === 'obf') {
        await interaction.deferReply();
        const attachment = interaction.options.getAttachment('file');
        const name = attachment.name || '';
        if (!name.match(/\.(lua|luau|txt)$/i))
            return interaction.editReply({ content: 'Only `.lua` / `.luau` / `.txt` allowed.' });
        if (attachment.size > MAX_SIZE)
            return interaction.editReply({ content: `Too large. Max ${(MAX_SIZE/1024).toFixed(0)} KB.` });

        try {
            const res = await fetch(attachment.url);
            const src = await res.text();
            const t0 = Date.now();
            const obf = obfuscate(src);
            const elapsed = Date.now() - t0;

            const outName = name.replace(/\.(lua|luau|txt)$/i, '.obf.lua');
            const file = new AttachmentBuilder(Buffer.from(obf, 'utf8'), { name: outName });
            const embed = new EmbedBuilder()
                .setTitle('Obfuscation Complete')
                .setColor(0x00FFAA)
                .addFields(
                    { name: 'Input', value: `${(src.length/1024).toFixed(2)} KB`, inline: true },
                    { name: 'Output', value: `${(obf.length/1024).toFixed(2)} KB`, inline: true },
                    { name: 'Time', value: `${elapsed} ms`, inline: true },
                )
                .setFooter({ text: 'JUIX Forge · discord.gg/kurokoai' })
                .setTimestamp();
            return interaction.editReply({ embeds: [embed], files: [file] });
        } catch (e) {
            console.error('[obf]', e);
            return interaction.editReply({ content: 'Failed:\n```\n' + (e.message || e).slice(0, 1800) + '\n```' });
        }
    }

    if (commandName === 'obftext') {
        await interaction.deferReply();
        const src = interaction.options.getString('source');
        if (src.length > MAX_SIZE)
            return interaction.editReply({ content: `Too large. Max ${(MAX_SIZE/1024).toFixed(0)} KB.` });
        try {
            const t0 = Date.now();
            const obf = obfuscate(src);
            const elapsed = Date.now() - t0;

            const file = new AttachmentBuilder(Buffer.from(obf, 'utf8'), { name: 'obfuscated.lua' });
            const embed = new EmbedBuilder()
                .setTitle('Obfuscation Complete')
                .setColor(0x00FFAA)
                .addFields(
                    { name: 'Input', value: `${(src.length/1024).toFixed(2)} KB`, inline: true },
                    { name: 'Output', value: `${(obf.length/1024).toFixed(2)} KB`, inline: true },
                    { name: 'Time', value: `${elapsed} ms`, inline: true },
                )
                .setFooter({ text: 'JUIX Forge · discord.gg/kurokoai' })
                .setTimestamp();
            return interaction.editReply({ embeds: [embed], files: [file] });
        } catch (e) {
            console.error('[obftext]', e);
            return interaction.editReply({ content: 'Failed:\n```\n' + (e.message || e).slice(0, 1800) + '\n```' });
        }
    }
});

client.login(TOKEN);
