-- ==================================================================
-- JUIX Forge Obfuscator v1.0
-- VM-based obfuscator with XOR+escape encoding
-- Made for JUIX | discord.gg/kurokoai
-- ==================================================================

local OBF = {}

-- ==================================================================
-- OPCODES
-- ==================================================================
local OP = {
    MOVE=1, LOADK=2, LOADNIL=3, LOADBOOL=4, LOADGLOBAL=5, STOREGLOBAL=6,
    ADD=7, SUB=8, MUL=9, DIV=10, MOD=11, POW=12, UNM=13, NOT=14, LEN=15,
    CONCAT=16, EQ=17, LT=18, LE=19, JMP=20, JZ=21, JNZ=22,
    CALL=23, RETURN=24, NEWTABLE=25, GETTABLE=26, SETTABLE=27,
    GETUPVAL=28, SETUPVAL=29, CLOSURE=30, VARARG=31,
}

-- ==================================================================
-- LEXER
-- ==================================================================
local Lexer = {}
Lexer.__index = Lexer

local KEYWORDS = {
    ["and"]=1,["break"]=1,["do"]=1,["else"]=1,["elseif"]=1,
    ["end"]=1,["false"]=1,["for"]=1,["function"]=1,["if"]=1,
    ["in"]=1,["local"]=1,["nil"]=1,["not"]=1,["or"]=1,
    ["repeat"]=1,["return"]=1,["then"]=1,["true"]=1,["until"]=1,
    ["while"]=1,
}

local function is_alpha(c) return c:match("[%a_]") end
local function is_digit(c) return c:match("%d") end
local function is_alnum(c) return c:match("[%w_]") end

function Lexer.new(src)
    return setmetatable({ src = src, pos = 1, line = 1, toks = {} }, Lexer)
end

function Lexer:peek(n) n = n or 0; return self.src:sub(self.pos + n, self.pos + n) end

function Lexer:advance()
    local c = self.src:sub(self.pos, self.pos)
    self.pos = self.pos + 1
    if c == "\n" then self.line = self.line + 1 end
    return c
end

function Lexer:add(typ, val)
    self.toks[#self.toks + 1] = { type = typ, value = val, line = self.line }
end

function Lexer:tokenize()
    while self.pos <= #self.src do
        local c = self:peek()
        if c:match("%s") then
            self:advance()
        elseif c == "-" and self:peek(1) == "-" then
            if self:peek(2) == "[" and self:peek(3) == "[" then
                self:advance(); self:advance(); self:advance()
                while self.pos <= #self.src do
                    if self:peek() == "]" and self:peek(1) == "]" then
                        self:advance(); self:advance(); break
                    end
                    self:advance()
                end
            else
                while self.pos <= #self.src and self:peek() ~= "\n" do self:advance() end
            end
        elseif is_alpha(c) then
            local start = self.pos
            while is_alnum(self:peek()) do self:advance() end
            local word = self.src:sub(start, self.pos - 1)
            self:add(KEYWORDS[word] and "keyword" or "name", word)
        elseif is_digit(c) or (c == "." and is_digit(self:peek(1))) then
            local start = self.pos
            local is_hex = false
            if c == "0" and (self:peek(1) == "x" or self:peek(1) == "X") then
                is_hex = true; self:advance(); self:advance()
                while self:peek():match("[%x%.]") do self:advance() end
            else
                while self:peek():match("[%d%.]") do self:advance() end
                if self:peek():match("[eE]") then
                    self:advance()
                    if self:peek():match("[%+%-]") then self:advance() end
                    while is_digit(self:peek()) do self:advance() end
                end
            end
            local n = tonumber(self.src:sub(start, self.pos - 1))
            if not n then error("bad number at line " .. self.line) end
            self:add("number", n)
        elseif c == "[" and (self:peek(1) == "[" or self:peek(1) == "=") then
            local eq_count = 0
            local p = 1
            while self:peek(p) == "=" do eq_count = eq_count + 1; p = p + 1 end
            if self:peek(p) == "[" then
                self:advance()
                for _ = 1, eq_count do self:advance() end
                self:advance()
                local buf = {}
                local closer = "]" .. string.rep("=", eq_count) .. "]"
                while self.pos <= #self.src do
                    if self.src:sub(self.pos, self.pos + #closer - 1) == closer then
                        for _ = 1, #closer do self:advance() end
                        break
                    end
                    buf[#buf + 1] = self:advance()
                end
                self:add("string", table.concat(buf))
            else
                error("bad long string at line " .. self.line)
            end
        elseif c == "\"" or c == "'" then
            local q = self:advance()
            local buf = {}
            while self.pos <= #self.src do
                local ch = self:peek()
                if ch == q then self:advance(); break
                elseif ch == "\\" then
                    self:advance()
                    local esc = self:advance()
                    local map = { n="\n", t="\t", r="\r", ["\\"]="\\", ["\""]="\"", ["'"]="'" }
                    if map[esc] then buf[#buf + 1] = map[esc]
                    elseif is_digit(esc) then
                        local n = esc
                        for _ = 1, 2 do
                            if is_digit(self:peek()) then n = n .. self:advance() end
                        end
                        buf[#buf + 1] = string.char(tonumber(n))
                    else buf[#buf + 1] = esc end
                else buf[#buf + 1] = self:advance() end
            end
            self:add("string", table.concat(buf))
        else
            local two = c .. self:peek(1)
            local three = two .. self:peek(2)
            local three_ops = { ["..."]=1 }
            local two_ops = { ["=="]=1,["~="]=1,["<="]=1,[">="]=1,[".."]=1,["::"]=1 }
            if three_ops[three] then
                self:advance(); self:advance(); self:advance()
                self:add("op", three)
            elseif two_ops[two] then
                self:advance(); self:advance()
                self:add("op", two)
            else
                self:advance()
                self:add("op", c)
            end
        end
    end
    self:add("eof", "<eof>")
    return self.toks
end

-- ==================================================================
-- PARSER
-- ==================================================================
local Parser = {}
Parser.__index = Parser

function Parser.new(toks)
    return setmetatable({ toks = toks, pos = 1 }, Parser)
end

function Parser:peek(n) return self.toks[self.pos + (n or 0)] end
function Parser:cur() return self.toks[self.pos] end
function Parser:next() local t = self.toks[self.pos]; self.pos = self.pos + 1; return t end

function Parser:check(typ, val)
    local t = self:cur()
    return t.type == typ and (val == nil or t.value == val)
end

function Parser:accept(typ, val)
    if self:check(typ, val) then return self:next() end
    return nil
end

function Parser:expect(typ, val)
    local t = self:cur()
    if not (t.type == typ and (val == nil or t.value == val)) then
        error(string.format("expected %s%s at line %d, got %s '%s'",
            typ, val and (" '"..val.."'") or "", t.line, t.type, tostring(t.value)))
    end
    return self:next()
end

local BINOP_PREC = {
    ["or"]=1,["and"]=2,
    ["<"]=3,[">"]=3,["<="]=3,[">="]=3,["~="]=3,["=="]=3,
    [".."]=4,
    ["+"]=5,["-"]=5,
    ["*"]=6,["/"]=6,["%"]=6,
    ["^"]=8,
}
local UNARY_PREC = 7

function Parser:parse_chunk()
    local body = self:parse_block()
    self:expect("eof")
    return { type = "Chunk", body = body }
end

function Parser:parse_block()
    local body = {}
    while true do
        local t = self:cur()
        if t.type == "eof" then break end
        if t.type == "keyword" and (t.value == "end" or t.value == "else"
            or t.value == "elseif" or t.value == "until") then break end
        body[#body + 1] = self:parse_statement()
    end
    return body
end

function Parser:parse_statement()
    local t = self:cur()
    if t.type == "op" and t.value == ";" then self:next(); return { type = "Empty" } end
    if t.type == "keyword" then
        if t.value == "local" then return self:parse_local() end
        if t.value == "if" then return self:parse_if() end
        if t.value == "while" then return self:parse_while() end
        if t.value == "repeat" then return self:parse_repeat() end
        if t.value == "for" then return self:parse_for() end
        if t.value == "function" then return self:parse_function_decl() end
        if t.value == "return" then return self:parse_return() end
        if t.value == "break" then self:next(); return { type = "Break" } end
        if t.value == "do" then
            self:next()
            local body = self:parse_block()
            self:expect("keyword", "end")
            return { type = "Do", body = body }
        end
    end
    return self:parse_expr_statement()
end

function Parser:parse_local()
    self:expect("keyword", "local")
    if self:check("keyword", "function") then
        self:next()
        local name = self:expect("name").value
        local fn = self:parse_function_body()
        return { type = "LocalFunction", name = name, func = fn }
    end
    local names = { self:expect("name").value }
    while self:accept("op", ",") do
        names[#names + 1] = self:expect("name").value
    end
    local exprs = {}
    if self:accept("op", "=") then
        exprs[1] = self:parse_expr()
        while self:accept("op", ",") do
            exprs[#exprs + 1] = self:parse_expr()
        end
    end
    return { type = "Local", names = names, exprs = exprs }
end

function Parser:parse_if()
    self:expect("keyword", "if")
    local cond = self:parse_expr()
    self:expect("keyword", "then")
    local body = self:parse_block()
    local clauses = { { cond = cond, body = body } }
    while self:check("keyword", "elseif") do
        self:next()
        local c = self:parse_expr()
        self:expect("keyword", "then")
        local b = self:parse_block()
        clauses[#clauses + 1] = { cond = c, body = b }
    end
    local else_body = nil
    if self:accept("keyword", "else") then
        else_body = self:parse_block()
    end
    self:expect("keyword", "end")
    return { type = "If", clauses = clauses, else_body = else_body }
end

function Parser:parse_while()
    self:expect("keyword", "while")
    local cond = self:parse_expr()
    self:expect("keyword", "do")
    local body = self:parse_block()
    self:expect("keyword", "end")
    return { type = "While", cond = cond, body = body }
end

function Parser:parse_repeat()
    self:expect("keyword", "repeat")
    local body = self:parse_block()
    self:expect("keyword", "until")
    local cond = self:parse_expr()
    return { type = "Repeat", body = body, cond = cond }
end

function Parser:parse_for()
    self:expect("keyword", "for")
    local first = self:expect("name").value
    if self:accept("op", "=") then
        local start = self:parse_expr()
        self:expect("op", ",")
        local stop = self:parse_expr()
        local step = nil
        if self:accept("op", ",") then step = self:parse_expr() end
        self:expect("keyword", "do")
        local body = self:parse_block()
        self:expect("keyword", "end")
        return { type = "ForNumeric", name = first, start = start, stop = stop,
                 step = step, body = body }
    else
        local names = { first }
        while self:accept("op", ",") do
            names[#names + 1] = self:expect("name").value
        end
        self:expect("keyword", "in")
        local exprs = { self:parse_expr() }
        while self:accept("op", ",") do
            exprs[#exprs + 1] = self:parse_expr()
        end
        self:expect("keyword", "do")
        local body = self:parse_block()
        self:expect("keyword", "end")
        return { type = "ForGeneric", names = names, exprs = exprs, body = body }
    end
end

function Parser:parse_function_decl()
    self:expect("keyword", "function")
    local parts = { self:expect("name").value }
    local is_method = false
    while true do
        if self:accept("op", ".") then
            parts[#parts + 1] = self:expect("name").value
        elseif self:accept("op", ":") then
            parts[#parts + 1] = self:expect("name").value
            is_method = true
            break
        else break end
    end
    local fn = self:parse_function_body(is_method)
    local target = { type = "Identifier", name = parts[1] }
    for i = 2, #parts do
        target = { type = "Index", base = target, key = { type = "StringLit", value = parts[i] } }
    end
    return { type = "Assign", targets = { target }, exprs = { fn } }
end

function Parser:parse_function_body(is_method)
    self:expect("op", "(")
    local params = {}
    if is_method then params[#params + 1] = "self" end
    if not self:check("op", ")") then
        repeat
            if self:check("op", "...") then
                self:next()
                params[#params + 1] = "..."
                break
            end
            params[#params + 1] = self:expect("name").value
        until not self:accept("op", ",")
    end
    self:expect("op", ")")
    local body = self:parse_block()
    self:expect("keyword", "end")
    return { type = "Function", params = params, body = body }
end

function Parser:parse_return()
    self:expect("keyword", "return")
    local exprs = {}
    if not (self:check("eof") or self:check("keyword", "end") or self:check("keyword", "else")
        or self:check("keyword", "elseif") or self:check("keyword", "until")
        or self:check("op", ";")) then
        exprs[1] = self:parse_expr()
        while self:accept("op", ",") do
            exprs[#exprs + 1] = self:parse_expr()
        end
    end
    self:accept("op", ";")
    return { type = "Return", exprs = exprs }
end

function Parser:parse_expr_statement()
    local expr = self:parse_suffixed_expr()
    if self:check("op", "=") or self:check("op", ",") then
        local targets = { expr }
        while self:accept("op", ",") do
            targets[#targets + 1] = self:parse_suffixed_expr()
        end
        self:expect("op", "=")
        local exprs = { self:parse_expr() }
        while self:accept("op", ",") do
            exprs[#exprs + 1] = self:parse_expr()
        end
        return { type = "Assign", targets = targets, exprs = exprs }
    end
    return { type = "CallStatement", expr = expr }
end

function Parser:parse_expr(min_prec)
    min_prec = min_prec or 1
    local left = self:parse_unary()
    while true do
        local t = self:cur()
        if t.type ~= "op" and t.type ~= "keyword" then break end
        local prec = BINOP_PREC[t.value]
        if not prec or prec < min_prec then break end
        local op = self:next().value
        local right_min = op == "^" and prec or prec + 1
        local right = self:parse_expr(right_min)
        left = { type = "Binary", op = op, left = left, right = right }
    end
    return left
end

function Parser:parse_unary()
    local t = self:cur()
    if (t.type == "op" and (t.value == "-" or t.value == "#"))
        or (t.type == "keyword" and t.value == "not") then
        local op = self:next().value
        local operand = self:parse_expr(UNARY_PREC)
        return { type = "Unary", op = op, operand = operand }
    end
    return self:parse_suffixed_expr()
end

function Parser:parse_suffixed_expr()
    local expr = self:parse_primary()
    while true do
        local t = self:cur()
        if t.type == "op" and t.value == "." then
            self:next()
            local key = self:expect("name").value
            expr = { type = "Index", base = expr, key = { type = "StringLit", value = key } }
        elseif t.type == "op" and t.value == "[" then
            self:next()
            local key = self:parse_expr()
            self:expect("op", "]")
            expr = { type = "Index", base = expr, key = key }
        elseif t.type == "op" and t.value == ":" then
            self:next()
            local method = self:expect("name").value
            local args = self:parse_call_args()
            expr = { type = "MethodCall", base = expr, method = method, args = args }
        elseif t.type == "op" and (t.value == "(" or t.value == "{") then
            local args = self:parse_call_args()
            expr = { type = "Call", base = expr, args = args }
        elseif t.type == "string" then
            local s = self:next().value
            expr = { type = "Call", base = expr, args = { { type = "StringLit", value = s } } }
        else break end
    end
    return expr
end

function Parser:parse_call_args()
    local t = self:cur()
    if t.type == "op" and t.value == "(" then
        self:next()
        local args = {}
        if not self:check("op", ")") then
            args[1] = self:parse_expr()
            while self:accept("op", ",") do
                args[#args + 1] = self:parse_expr()
            end
        end
        self:expect("op", ")")
        return args
    elseif t.type == "op" and t.value == "{" then
        return { self:parse_table() }
    elseif t.type == "string" then
        self:next()
        return { { type = "StringLit", value = t.value } }
    else
        error("expected call args at line " .. t.line)
    end
end

function Parser:parse_primary()
    local t = self:cur()
    if t.type == "number" then self:next(); return { type = "NumberLit", value = t.value } end
    if t.type == "string" then self:next(); return { type = "StringLit", value = t.value } end
    if t.type == "name" then self:next(); return { type = "Identifier", name = t.value } end
    if t.type == "keyword" then
        if t.value == "nil" then self:next(); return { type = "NilLit" } end
        if t.value == "true" then self:next(); return { type = "BoolLit", value = true } end
        if t.value == "false" then self:next(); return { type = "BoolLit", value = false } end
        if t.value == "function" then self:next(); return self:parse_function_body() end
    end
    if t.type == "op" then
        if t.value == "(" then
            self:next()
            local e = self:parse_expr()
            self:expect("op", ")")
            return e
        end
        if t.value == "{" then return self:parse_table() end
        if t.value == "..." then self:next(); return { type = "Vararg" } end
    end
    error(string.format("unexpected token '%s' (%s) at line %d",
        tostring(t.value), t.type, t.line))
end

function Parser:parse_table()
    self:expect("op", "{")
    local fields = {}
    while not self:check("op", "}") do
        if self:check("op", "[") then
            self:next()
            local key = self:parse_expr()
            self:expect("op", "]")
            self:expect("op", "=")
            local val = self:parse_expr()
            fields[#fields + 1] = { type = "KeyField", key = key, value = val }
        elseif self:check("name") and self:peek(1).type == "op" and self:peek(1).value == "=" then
            local key = self:next().value
            self:expect("op", "=")
            local val = self:parse_expr()
            fields[#fields + 1] = { type = "NameField", key = key, value = val }
        else
            local val = self:parse_expr()
            fields[#fields + 1] = { type = "ArrayField", value = val }
        end
        if not self:accept("op", ",") and not self:accept("op", ";") then break end
    end
    self:expect("op", "}")
    return { type = "Table", fields = fields }
end

-- ==================================================================
-- COMPILER
-- ==================================================================
local Compiler = {}
Compiler.__index = Compiler

function Compiler.new()
    return setmetatable({
        code = {}, consts = {}, const_map = {},
        scopes = {}, reg_top = 0, max_reg = 0, funcs = {},
    }, Compiler)
end

function Compiler:add_const(v)
    local key = type(v) .. ":" .. tostring(v)
    if self.const_map[key] then return self.const_map[key] end
    local idx = #self.consts
    self.consts[idx + 1] = v
    self.const_map[key] = idx
    return idx
end

function Compiler:emit(op, A, B, C)
    self.code[#self.code + 1] = { op = op, A = A or 0, B = B or 0, C = C or 0 }
    return #self.code
end

function Compiler:alloc_reg()
    self.reg_top = self.reg_top + 1
    if self.reg_top > self.max_reg then self.max_reg = self.reg_top end
    return self.reg_top - 1
end

function Compiler:free_reg(n)
    self.reg_top = self.reg_top - (n or 1)
end

function Compiler:push_scope() self.scopes[#self.scopes + 1] = {} end
function Compiler:pop_scope() self.scopes[#self.scopes] = nil end

function Compiler:declare_var(name, reg)
    self.scopes[#self.scopes][name] = reg
end

function Compiler:find_var(name)
    for i = #self.scopes, 1, -1 do
        if self.scopes[i][name] then return self.scopes[i][name] end
    end
    return nil
end

function Compiler:compile_expr(node)
    local t = node.type
    if t == "NumberLit" or t == "StringLit" then
        local r = self:alloc_reg()
        self:emit(OP.LOADK, r, self:add_const(node.value), 0)
        return r
    elseif t == "BoolLit" then
        local r = self:alloc_reg()
        self:emit(OP.LOADBOOL, r, node.value and 1 or 0, 0)
        return r
    elseif t == "NilLit" then
        local r = self:alloc_reg()
        self:emit(OP.LOADNIL, r, 0, 0)
        return r
    elseif t == "Identifier" then
        local r = self:alloc_reg()
        local lr = self:find_var(node.name)
        if lr then
            self:emit(OP.MOVE, r, lr, 0)
        else
            self:emit(OP.LOADGLOBAL, r, self:add_const(node.name), 0)
        end
        return r
    elseif t == "Vararg" then
        local r = self:alloc_reg()
        self:emit(OP.VARARG, r, 0, 0)
        return r
    elseif t == "Binary" then
        local l = self:compile_expr(node.left)
        local r = self:compile_expr(node.right)
        local dst = l
        local op_map = {
            ["+"]=OP.ADD,["-"]=OP.SUB,["*"]=OP.MUL,["/"]=OP.DIV,
            ["%"]=OP.MOD,["^"]=OP.POW,[".."]=OP.CONCAT,
            ["=="]=OP.EQ,["~="]=OP.EQ,
            ["<"]=OP.LT,[">"]=OP.LT,["<="]=OP.LE,[">="]=OP.LE,
        }
        local op = op_map[node.op]
        if not op then error("unsupported binop: " .. node.op) end
        local swap = (node.op == ">" or node.op == ">=" or node.op == "~=")
        if swap then self:emit(op, dst, r, l)
        else self:emit(op, dst, l, r) end
        if node.op == "~=" then self:emit(OP.NOT, dst, dst, 0) end
        self:free_reg(1)
        return dst
    elseif t == "Unary" then
        local src = self:compile_expr(node.operand)
        local op_map = { ["-"]=OP.UNM, ["not"]=OP.NOT, ["#"]=OP.LEN }
        self:emit(op_map[node.op], src, src, 0)
        return src
    elseif t == "Table" then
        local r = self:alloc_reg()
        self:emit(OP.NEWTABLE, r, #node.fields, 0)
        local array_idx = 1
        for _, f in ipairs(node.fields) do
            if f.type == "ArrayField" then
                local vr = self:compile_expr(f.value)
                local kr = self:alloc_reg()
                self:emit(OP.LOADK, kr, self:add_const(array_idx), 0)
                self:emit(OP.SETTABLE, r, kr, vr)
                self:free_reg(2)
                array_idx = array_idx + 1
            elseif f.type == "NameField" or f.type == "KeyField" then
                local kr, vr
                if f.type == "NameField" then
                    kr = self:alloc_reg()
                    self:emit(OP.LOADK, kr, self:add_const(f.key), 0)
                else kr = self:compile_expr(f.key) end
                vr = self:compile_expr(f.value)
                self:emit(OP.SETTABLE, r, kr, vr)
                self:free_reg(2)
            end
        end
        return r
    elseif t == "Index" then
        local base = self:compile_expr(node.base)
        local key = self:compile_expr(node.key)
        self:emit(OP.GETTABLE, base, base, key)
        self:free_reg(1)
        return base
    elseif t == "Call" then
        local f = self:compile_expr(node.base)
        local save = self:alloc_reg()
        self:emit(OP.MOVE, save, f, 0)
        local nargs = 0
        for _, a in ipairs(node.args) do
            self:compile_expr(a); nargs = nargs + 1
        end
        self:emit(OP.CALL, save, nargs, 1)
        self:free_reg(nargs)
        return save
    elseif t == "MethodCall" then
        local base = self:compile_expr(node.base)
        local kr = self:alloc_reg()
        self:emit(OP.LOADK, kr, self:add_const(node.method), 0)
        local fr = self:alloc_reg()
        self:emit(OP.GETTABLE, fr, base, kr)
        self:free_reg(2)
        local save = self:alloc_reg()
        self:emit(OP.MOVE, save, fr, 0)
        local self_r = self:alloc_reg()
        self:emit(OP.MOVE, self_r, base, 0)
        local nargs = 1
        for _, a in ipairs(node.args) do
            self:compile_expr(a); nargs = nargs + 1
        end
        self:emit(OP.CALL, save, nargs, 1)
        self:free_reg(nargs)
        self:free_reg(1)
        return save
    elseif t == "Function" then
        local sub = Compiler.new()
        sub:push_scope()
        for i, p in ipairs(node.params) do
            sub:declare_var(p, i - 1)
        end
        sub.reg_top = #node.params
        sub.max_reg = #node.params
        sub:compile_block(node.body)
        sub:emit(OP.RETURN, 0, 0, 0)
        local proto_idx = #self.funcs
        self.funcs[proto_idx + 1] = sub
        local r = self:alloc_reg()
        self:emit(OP.CLOSURE, r, proto_idx, 0)
        return r
    end
    error("unsupported expr: " .. tostring(t))
end

function Compiler:compile_statement(node)
    local t = node.type
    if t == "Local" then
        for i, name in ipairs(node.names) do
            local r = self:alloc_reg()
            self:declare_var(name, r)
            if node.exprs[i] then
                local er = self:compile_expr(node.exprs[i])
                if er ~= r then self:emit(OP.MOVE, r, er, 0) end
                self:free_reg(1)
            else
                self:emit(OP.LOADNIL, r, 0, 0)
            end
        end
    elseif t == "LocalFunction" then
        local r = self:alloc_reg()
        self:declare_var(node.name, r)
        local er = self:compile_expr(node.func)
        if er ~= r then self:emit(OP.MOVE, r, er, 0) end
        self:free_reg(1)
    elseif t == "Assign" then
        local val_regs = {}
        for i, e in ipairs(node.exprs) do
            val_regs[i] = self:compile_expr(e)
        end
        for i, tgt in ipairs(node.targets) do
            local vr = val_regs[i] or val_regs[#val_regs]
            if tgt.type == "Identifier" then
                local lr = self:find_var(tgt.name)
                if lr then self:emit(OP.MOVE, lr, vr, 0)
                else self:emit(OP.STOREGLOBAL, self:add_const(tgt.name), vr, 0) end
            elseif tgt.type == "Index" then
                local b = self:compile_expr(tgt.base)
                local k = self:compile_expr(tgt.key)
                self:emit(OP.SETTABLE, b, k, vr)
            end
        end
        self:free_reg(#node.exprs)
    elseif t == "CallStatement" then
        self:compile_expr(node.expr)
        self:free_reg(1)
    elseif t == "If" then
        local end_jumps = {}
        for i, clause in ipairs(node.clauses) do
            local cr = self:compile_expr(clause.cond)
            local jz = self:emit(OP.JZ, cr, 0, 0)
            self:free_reg(1)
            self:compile_block(clause.body)
            if i < #node.clauses or node.else_body then
                end_jumps[#end_jumps + 1] = self:emit(OP.JMP, 0, 0, 0)
            end
            self.code[jz].B = #self.code + 1
        end
        if node.else_body then self:compile_block(node.else_body) end
        for _, j in ipairs(end_jumps) do self.code[j].A = #self.code + 1 end
    elseif t == "While" then
        local start = #self.code + 1
        local cr = self:compile_expr(node.cond)
        local jz = self:emit(OP.JZ, cr, 0, 0)
        self:free_reg(1)
        self:compile_block(node.body)
        self:emit(OP.JMP, start, 0, 0)
        self.code[jz].B = #self.code + 1
    elseif t == "Repeat" then
        local start = #self.code + 1
        self:compile_block(node.body)
        local cr = self:compile_expr(node.cond)
        self:emit(OP.JZ, cr, start, 0)
        self:free_reg(1)
    elseif t == "ForNumeric" then
        local var_reg = self:alloc_reg()
        self:push_scope()
        self:declare_var(node.name, var_reg)
        local sr = self:compile_expr(node.start)
        self:emit(OP.MOVE, var_reg, sr, 0)
        self:free_reg(1)
        local limit_r = self:alloc_reg()
        local lr = self:compile_expr(node.stop)
        self:emit(OP.MOVE, limit_r, lr, 0)
        self:free_reg(1)
        local step_r = self:alloc_reg()
        if node.step then
            local str = self:compile_expr(node.step)
            self:emit(OP.MOVE, step_r, str, 0)
            self:free_reg(1)
        else
            self:emit(OP.LOADK, step_r, self:add_const(1), 0)
        end
        local start = #self.code + 1
        local tmp = self:alloc_reg()
        self:emit(OP.LE, tmp, var_reg, limit_r)
        local jz = self:emit(OP.JZ, tmp, 0, 0)
        self:free_reg(1)
        self:compile_block(node.body)
        local inc = self:alloc_reg()
        self:emit(OP.ADD, inc, var_reg, step_r)
        self:emit(OP.MOVE, var_reg, inc, 0)
        self:free_reg(1)
        self:emit(OP.JMP, start, 0, 0)
        self.code[jz].B = #self.code + 1
        self:pop_scope()
        self:free_reg(3)
    elseif t == "Return" then
        local regs = {}
        for i, e in ipairs(node.exprs) do regs[i] = self:compile_expr(e) end
        self:emit(OP.RETURN, #regs, 0, 0)
        self:free_reg(#regs)
    elseif t == "Break" then
        self:emit(OP.JMP, 0, 0, 0)
    elseif t == "Do" then
        self:push_scope()
        self:compile_block(node.body)
        self:pop_scope()
    elseif t == "Empty" then
        -- skip
    elseif t == "ForGeneric" then
        error("generic for not supported in v1")
    else
        error("unsupported stmt: " .. tostring(t))
    end
end

function Compiler:compile_block(block)
    for _, stmt in ipairs(block) do self:compile_statement(stmt) end
end

function Compiler:compile(chunk)
    self:push_scope()
    self:compile_block(chunk.body)
    self:emit(OP.RETURN, 0, 0, 0)
    self:pop_scope()
    return { code = self.code, consts = self.consts, max_reg = self.max_reg, funcs = self.funcs }
end

-- ==================================================================
-- ENCODER
-- ==================================================================
local Encoder = {}

local function write_u16(n) return string.char(n % 256, math.floor(n / 256) % 256) end
local function write_u32(n)
    return string.char(
        n % 256,
        math.floor(n / 256) % 256,
        math.floor(n / 65536) % 256,
        math.floor(n / 16777216) % 256
    )
end
local function write_str(s) return write_u32(#s) .. s end

local function serialize_value(v)
    local t = type(v)
    if t == "number" then return "\1" .. write_str(tostring(v))
    elseif t == "string" then return "\2" .. write_str(v)
    elseif t == "boolean" then return v and "\3" or "\4"
    elseif t == "nil" then return "\5"
    else error("cannot serialize: " .. t) end
end

local function serialize_proto(proto)
    local out = {}
    out[#out + 1] = write_u16(proto.max_reg)
    out[#out + 1] = write_u16(#proto.consts)
    for _, v in ipairs(proto.consts) do
        out[#out + 1] = serialize_value(v)
    end
    out[#out + 1] = write_u32(#proto.code)
    for _, ins in ipairs(proto.code) do
        out[#out + 1] = string.char(ins.op, ins.A, ins.B, ins.C)
    end
    out[#out + 1] = write_u16(#proto.funcs)
    for _, sub in ipairs(proto.funcs) do
        out[#out + 1] = write_str(serialize_proto(sub))
    end
    return table.concat(out)
end

function Encoder.encode(compiled)
    local raw = serialize_proto(compiled)
    local h = 5381
    for i = 1, #raw do
        h = (h * 33 + string.byte(raw, i)) % 4294967296
    end
    local key = {}
    for i = 1, 32 do
        key[i] = (h * i + 0x5BD1E995) % 256
    end
    local bytes = {}
    for i = 1, #raw do
        local b = string.byte(raw, i)
        local k = key[((i - 1) % 32) + 1]
        local x = bit32.bxor(b, k)
        bytes[i] = "\\" .. x
    end
    local keystr = {}
    for i = 1, #key do
        keystr[i] = "\\" .. key[i]
    end
    return table.concat(bytes), table.concat(keystr)
end

-- ==================================================================
-- LOADER TEMPLATE
-- ==================================================================
local LOADER = [==[
local PAYLOAD = "__PAYLOAD__"
local KEYSTR = "__KEY__"

local function dec(s)
    local out = {}
    for i = 1, #s do out[i] = string.char(string.byte(s, i)) end
    return table.concat(out)
end

local payload = dec(PAYLOAD)
local keybytes = dec(KEYSTR)

local function bxor8(a, b)
    local r, p = 0, 1
    while a > 0 or b > 0 do
        local aa, bb = a % 2, b % 2
        if aa ~= bb then r = r + p end
        a, b, p = math.floor(a / 2), math.floor(b / 2), p * 2
    end
    return r
end

local raw = {}
for i = 1, #payload do
    local b = string.byte(payload, i)
    local k = string.byte(keybytes, ((i - 1) % #keybytes) + 1)
    raw[i] = bxor8(b, k)
end
local bytes = table.concat(raw)

local pos = 1
local function rd_u8()
    local b = string.byte(bytes, pos); pos = pos + 1; return b
end
local function rd_u16()
    local a, b = string.byte(bytes, pos, pos + 1); pos = pos + 2
    return a + b * 256
end
local function rd_u32()
    local a, b, c, d = string.byte(bytes, pos, pos + 3); pos = pos + 4
    return a + b * 256 + c * 65536 + d * 16777216
end
local function rd_str()
    local n = rd_u32()
    local s = string.sub(bytes, pos, pos + n - 1); pos = pos + n
    return s
end
local function rd_value()
    local t = rd_u8()
    if t == 1 then return tonumber(rd_str())
    elseif t == 2 then return rd_str()
    elseif t == 3 then return true
    elseif t == 4 then return false
    elseif t == 5 then return nil end
    error("bad const tag")
end

local function read_proto()
    local proto = {}
    proto.max_reg = rd_u16()
    local nconsts = rd_u16()
    proto.consts = {}
    for i = 1, nconsts do proto.consts[i] = rd_value() end
    local ncode = rd_u32()
    proto.code = {}
    for i = 1, ncode do
        local op, A, B, C = rd_u8(), rd_u8(), rd_u8(), rd_u8()
        proto.code[i] = { op = op, A = A, B = B, C = C }
    end
    local nsub = rd_u16()
    proto.funcs = {}
    for i = 1, nsub do
        local sub_bytes = rd_str()
        local save_pos, save_bytes = pos, bytes
        pos, bytes = 1, sub_bytes
        proto.funcs[i] = read_proto()
        pos, bytes = save_pos, save_bytes
    end
    return proto
end

local main_proto = read_proto()

local OP = {
    MOVE=1, LOADK=2, LOADNIL=3, LOADBOOL=4, LOADGLOBAL=5, STOREGLOBAL=6,
    ADD=7, SUB=8, MUL=9, DIV=10, MOD=11, POW=12, UNM=13, NOT=14, LEN=15,
    CONCAT=16, EQ=17, LT=18, LE=19, JMP=20, JZ=21, JNZ=22,
    CALL=23, RETURN=24, NEWTABLE=25, GETTABLE=26, SETTABLE=27,
    GETUPVAL=28, SETUPVAL=29, CLOSURE=30, VARARG=31,
}

local function is_truthy(v) return v ~= nil and v ~= false end

local function run_proto(proto, args)
    local regs = {}
    for i = 1, proto.max_reg + 8 do regs[i] = nil end
    for i = 1, #args do regs[i - 1] = args[i] end
    local pc = 1
    local code = proto.code
    local consts = proto.consts

    while pc <= #code do
        local ins = code[pc]
        local op, A, B, C = ins.op, ins.A, ins.B, ins.C
        pc = pc + 1

        if op == OP.MOVE then regs[A] = regs[B]
        elseif op == OP.LOADK then regs[A] = consts[B + 1]
        elseif op == OP.LOADNIL then regs[A] = nil
        elseif op == OP.LOADBOOL then regs[A] = (B == 1)
        elseif op == OP.LOADGLOBAL then regs[A] = _G[consts[B + 1]]
        elseif op == OP.STOREGLOBAL then _G[consts[A + 1]] = regs[B]
        elseif op == OP.ADD then regs[A] = regs[B] + regs[C]
        elseif op == OP.SUB then regs[A] = regs[B] - regs[C]
        elseif op == OP.MUL then regs[A] = regs[B] * regs[C]
        elseif op == OP.DIV then regs[A] = regs[B] / regs[C]
        elseif op == OP.MOD then regs[A] = regs[B] % regs[C]
        elseif op == OP.POW then regs[A] = regs[B] ^ regs[C]
        elseif op == OP.UNM then regs[A] = -regs[B]
        elseif op == OP.NOT then regs[A] = not regs[B]
        elseif op == OP.LEN then regs[A] = #regs[B]
        elseif op == OP.CONCAT then regs[A] = tostring(regs[B]) .. tostring(regs[C])
        elseif op == OP.EQ then regs[A] = (regs[B] == regs[C])
        elseif op == OP.LT then regs[A] = (regs[B] < regs[C])
        elseif op == OP.LE then regs[A] = (regs[B] <= regs[C])
        elseif op == OP.JMP then pc = A
        elseif op == OP.JZ then if not is_truthy(regs[A]) then pc = B end
        elseif op == OP.JNZ then if is_truthy(regs[A]) then pc = B end
        elseif op == OP.CALL then
            local f = regs[A]
            local nargs2 = B
            local nres = C
            local call_args = {}
            for i = 1, nargs2 do call_args[i] = regs[A + i] end
            local results = { f(table.unpack(call_args)) }
            for i = 1, nres do regs[A + i - 1] = results[i] end
        elseif op == OP.RETURN then
            local rets = {}
            for i = 0, A - 1 do rets[i + 1] = regs[i] end
            return table.unpack(rets)
        elseif op == OP.NEWTABLE then regs[A] = {}
        elseif op == OP.GETTABLE then regs[A] = regs[B][regs[C]]
        elseif op == OP.SETTABLE then regs[A][regs[B]] = regs[C]
        elseif op == OP.CLOSURE then
            local sub = proto.funcs[B]
            regs[A] = function(...) return run_proto(sub, {...}) end
        elseif op == OP.VARARG then regs[A] = nil
        else error("bad op: " .. tostring(op)) end
    end
end

return run_proto(main_proto, {})
]==]

-- ==================================================================
-- PUBLIC API
-- ==================================================================
function OBF.obfuscate(src)
    local lexer = Lexer.new(src)
    local toks = lexer:tokenize()
    local parser = Parser.new(toks)
    local ast = parser:parse_chunk()
    local compiler = Compiler.new()
    local compiled = compiler:compile(ast)
    local payload, key = Encoder.encode(compiled)
    local out = LOADER
    out = out:gsub("__PAYLOAD__", function() return payload end)
    out = out:gsub("__KEY__", function() return key end)
    return out
end

return OBF
