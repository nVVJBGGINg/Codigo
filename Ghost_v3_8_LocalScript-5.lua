--[[
    GHOST v3.8 - Painel de treinamento / diagnóstico
    Roblox Studio | LocalScript
    Coloque em StarterPlayer > StarterPlayerScripts.

    Esta versão contém somente interface, preferências locais e diagnóstico.
    Não inclui bypass, interceptação de RemoteEvents, mira contra jogadores,
    ESP de jogadores ou automação de eliminação.
]]

-- PARTE 01 - SERVIÇOS E CONFIGURAÇÕES
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

local Config = {
    Enabled = true,
    AimTraining = false,
    ShowFOV = true,
    FOV = 100,
    Smoothness = 5,
    ShowNPCNames = false,
    WalkSpeedDisplay = 16,
    AntiAFKReminder = false,
}

local Logs = {}
local MAX_LOGS = 100
local Connections = {}
local CurrentTab = nil
local TabPages = {}
local TabButtons = {}

-- PARTE 02 - FUNÇÕES AUXILIARES E LOGS
local function AddLog(kind, message)
    local item = {
        Time = os.date("%H:%M:%S"),
        Kind = tostring(kind or "INFO"),
        Message = tostring(message),
    }
    table.insert(Logs, 1, item)
    if #Logs > MAX_LOGS then
        table.remove(Logs)
    end
    if _G.GhostRefreshLogs then
        _G.GhostRefreshLogs()
    end
    print(("[Ghost] [%s] %s"):format(item.Kind, item.Message))
end

local function TrackConnection(connection)
    table.insert(Connections, connection)
    return connection
end

local function Make(className, properties, parent)
    local object = Instance.new(className)
    for key, value in pairs(properties or {}) do
        object[key] = value
    end
    object.Parent = parent
    return object
end

local function AddCorner(object, radius)
    Make("UICorner", {CornerRadius = UDim.new(0, radius or 8)}, object)
end

local function AddStroke(object, color, thickness)
    Make("UIStroke", {
        Color = color or Color3.fromRGB(55, 65, 75),
        Thickness = thickness or 1,
        Transparency = 0,
    }, object)
end

-- PARTE 03 - JANELA PRINCIPAL
local ScreenGui = Make("ScreenGui", {
    Name = "GhostV38",
    ResetOnSpawn = false,
    ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
}, PlayerGui)

local Border = Make("Frame", {
    Name = "Border",
    Size = UDim2.fromOffset(506, 356),
    Position = UDim2.fromScale(0.5, 0.5),
    AnchorPoint = Vector2.new(0.5, 0.5),
    BackgroundColor3 = Color3.fromRGB(55, 65, 75),
    BorderSizePixel = 0,
}, ScreenGui)
AddCorner(Border, 16)

local Panel = Make("Frame", {
    Name = "Panel",
    Size = UDim2.fromOffset(500, 350),
    Position = UDim2.fromScale(0.5, 0.5),
    AnchorPoint = Vector2.new(0.5, 0.5),
    BackgroundColor3 = Color3.fromRGB(20, 22, 26),
    BorderSizePixel = 0,
}, ScreenGui)
AddCorner(Panel, 14)
AddStroke(Panel, Color3.fromRGB(65, 80, 95), 1)

local Header = Make("Frame", {
    Name = "Header",
    Size = UDim2.new(1, 0, 0, 48),
    BackgroundColor3 = Color3.fromRGB(28, 31, 37),
    BorderSizePixel = 0,
}, Panel)
AddCorner(Header, 14)

Make("TextLabel", {
    Name = "Title",
    Size = UDim2.new(1, -110, 1, 0),
    Position = UDim2.fromOffset(15, 0),
    BackgroundTransparency = 1,
    Text = "👻 Ghost v3.8",
    Font = Enum.Font.GothamBold,
    TextSize = 17,
    TextXAlignment = Enum.TextXAlignment.Left,
    TextColor3 = Color3.fromRGB(225, 230, 235),
}, Header)

local MinimizeButton = Make("TextButton", {
    Name = "Minimize",
    Size = UDim2.fromOffset(30, 30),
    Position = UDim2.new(1, -70, 0.5, -15),
    BackgroundColor3 = Color3.fromRGB(42, 46, 54),
    Text = "—",
    Font = Enum.Font.GothamBold,
    TextSize = 18,
    TextColor3 = Color3.fromRGB(230, 230, 230),
    AutoButtonColor = true,
}, Header)
AddCorner(MinimizeButton, 6)

local CloseButton = Make("TextButton", {
    Name = "Close",
    Size = UDim2.fromOffset(30, 30),
    Position = UDim2.new(1, -35, 0.5, -15),
    BackgroundColor3 = Color3.fromRGB(65, 38, 42),
    Text = "×",
    Font = Enum.Font.GothamBold,
    TextSize = 20,
    TextColor3 = Color3.fromRGB(255, 225, 225),
    AutoButtonColor = true,
}, Header)
AddCorner(CloseButton, 6)

Make("Frame", {
    Name = "Separator",
    Size = UDim2.new(1, 0, 0, 1),
    Position = UDim2.fromOffset(0, 48),
    BackgroundColor3 = Color3.fromRGB(55, 60, 68),
    BorderSizePixel = 0,
}, Panel)

-- PARTE 04 - ARRASTAR, MINIMIZAR E ABAS
local dragging = false
local dragStart = nil
local panelStart = nil

TrackConnection(Header.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then
        dragging = true
        dragStart = input.Position
        panelStart = Panel.Position
    end
end))

TrackConnection(UserInputService.InputChanged:Connect(function(input)
    if not dragging then return end
    if input.UserInputType == Enum.UserInputType.MouseMovement
        or input.UserInputType == Enum.UserInputType.Touch then
        local delta = input.Position - dragStart
        Panel.Position = UDim2.new(
            panelStart.X.Scale, panelStart.X.Offset + delta.X,
            panelStart.Y.Scale, panelStart.Y.Offset + delta.Y
        )
        Border.Position = Panel.Position
    end
end))

TrackConnection(UserInputService.InputEnded:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then
        dragging = false
    end
end))

local TabBar = Make("Frame", {
    Name = "TabBar",
    Size = UDim2.new(1, -20, 0, 36),
    Position = UDim2.fromOffset(10, 57),
    BackgroundTransparency = 1,
}, Panel)

Make("UIListLayout", {
    FillDirection = Enum.FillDirection.Horizontal,
    Padding = UDim.new(0, 7),
    SortOrder = Enum.SortOrder.LayoutOrder,
}, TabBar)

local ContentHolder = Make("Frame", {
    Name = "ContentHolder",
    Size = UDim2.new(1, -20, 1, -105),
    Position = UDim2.fromOffset(10, 98),
    BackgroundTransparency = 1,
}, Panel)

local function CreateTab(name)
    local button = Make("TextButton", {
        Name = name .. "Tab",
        Size = UDim2.fromOffset(112, 30),
        BackgroundColor3 = Color3.fromRGB(36, 40, 47),
        Text = name,
        Font = Enum.Font.GothamMedium,
        TextSize = 12,
        TextColor3 = Color3.fromRGB(215, 220, 225),
        AutoButtonColor = true,
    }, TabBar)
    AddCorner(button, 15)

    local page = Make("ScrollingFrame", {
        Name = name .. "Page",
        Size = UDim2.fromScale(1, 1),
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        ScrollBarThickness = 4,
        ScrollBarImageColor3 = Color3.fromRGB(90, 145, 180),
        CanvasSize = UDim2.new(),
        AutomaticCanvasSize = Enum.AutomaticSize.Y,
        Visible = false,
    }, ContentHolder)

    Make("UIListLayout", {
        Padding = UDim.new(0, 8),
        SortOrder = Enum.SortOrder.LayoutOrder,
    }, page)

    Make("UIPadding", {
        PaddingRight = UDim.new(0, 5),
        PaddingBottom = UDim.new(0, 8),
    }, page)

    TabPages[name] = page
    TabButtons[name] = button

    TrackConnection(button.MouseButton1Click:Connect(function()
        for tabName, tabPage in pairs(TabPages) do
            tabPage.Visible = (tabName == name)
            TabButtons[tabName].BackgroundColor3 =
                tabName == name
                and Color3.fromRGB(55, 105, 130)
                or Color3.fromRGB(36, 40, 47)
        end
        CurrentTab = name
    end))

    return page
end

local AimPage = CreateTab("Aim treino")
local FOVPage = CreateTab("FOV")
local VisualPage = CreateTab("Visual")
local ConfigPage = CreateTab("Config")
local LogsPage = CreateTab("Logs")

TabPages["Aim treino"].Visible = true
TabButtons["Aim treino"].BackgroundColor3 = Color3.fromRGB(55, 105, 130)
CurrentTab = "Aim treino"

local fullSize = UDim2.fromOffset(500, 350)
local miniSize = UDim2.fromOffset(500, 48)
local minimized = false

TrackConnection(MinimizeButton.MouseButton1Click:Connect(function()
    minimized = not minimized
    Panel.Size = minimized and miniSize or fullSize
    Border.Size = minimized
        and UDim2.fromOffset(506, 54)
        or UDim2.fromOffset(506, 356)
    TabBar.Visible = not minimized
    ContentHolder.Visible = not minimized
    MinimizeButton.Text = minimized and "+" or "—"
end))

TrackConnection(CloseButton.MouseButton1Click:Connect(function()
    ScreenGui:Destroy()
end))

-- PARTE 05 - COMPONENTES DE INTERFACE
local function CreateSection(parent, title)
    local label = Make("TextLabel", {
        Size = UDim2.new(1, 0, 0, 24),
        BackgroundTransparency = 1,
        Text = string.upper(title),
        Font = Enum.Font.GothamBold,
        TextSize = 11,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextColor3 = Color3.fromRGB(115, 175, 200),
    }, parent)
    return label
end

local function CreateToggle(parent, title, initial, callback)
    local row = Make("Frame", {
        Size = UDim2.new(1, -2, 0, 38),
        BackgroundColor3 = Color3.fromRGB(28, 31, 37),
        BorderSizePixel = 0,
    }, parent)
    AddCorner(row, 7)

    Make("TextLabel", {
        Size = UDim2.new(1, -65, 1, 0),
        Position = UDim2.fromOffset(10, 0),
        BackgroundTransparency = 1,
        Text = title,
        Font = Enum.Font.Gotham,
        TextSize = 12,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextColor3 = Color3.fromRGB(220, 225, 230),
    }, row)

    local state = initial == true
    local toggle = Make("TextButton", {
        Size = UDim2.fromOffset(42, 22),
        Position = UDim2.new(1, -52, 0.5, -11),
        BackgroundColor3 = state
            and Color3.fromRGB(35, 150, 115)
            or Color3.fromRGB(65, 70, 78),
        Text = state and "ON" or "OFF",
        Font = Enum.Font.GothamBold,
        TextSize = 9,
        TextColor3 = Color3.fromRGB(255, 255, 255),
        AutoButtonColor = true,
    }, row)
    AddCorner(toggle, 11)

    TrackConnection(toggle.MouseButton1Click:Connect(function()
        state = not state
        toggle.Text = state and "ON" or "OFF"
        toggle.BackgroundColor3 = state
            and Color3.fromRGB(35, 150, 115)
            or Color3.fromRGB(65, 70, 78)
        if callback then callback(state) end
    end))

    return row
end

local function CreateSlider(parent, title, minValue, maxValue, initial, callback)
    local row = Make("Frame", {
        Size = UDim2.new(1, -2, 0, 62),
        BackgroundColor3 = Color3.fromRGB(28, 31, 37),
        BorderSizePixel = 0,
    }, parent)
    AddCorner(row, 7)

    local titleLabel = Make("TextLabel", {
        Size = UDim2.new(1, -75, 0, 22),
        Position = UDim2.fromOffset(10, 5),
        BackgroundTransparency = 1,
        Text = title,
        Font = Enum.Font.Gotham,
        TextSize = 12,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextColor3 = Color3.fromRGB(220, 225, 230),
    }, row)

    local valueLabel = Make("TextLabel", {
        Size = UDim2.fromOffset(65, 22),
        Position = UDim2.new(1, -72, 0, 5),
        BackgroundTransparency = 1,
        Text = tostring(initial),
        Font = Enum.Font.GothamBold,
        TextSize = 12,
        TextXAlignment = Enum.TextXAlignment.Right,
        TextColor3 = Color3.fromRGB(120, 195, 220),
    }, row)

    local bar = Make("Frame", {
        Size = UDim2.new(1, -22, 0, 7),
        Position = UDim2.fromOffset(11, 39),
        BackgroundColor3 = Color3.fromRGB(55, 60, 68),
        BorderSizePixel = 0,
    }, row)
    AddCorner(bar, 5)

    local fill = Make("Frame", {
        Size = UDim2.new(0, 0, 1, 0),
        BackgroundColor3 = Color3.fromRGB(65, 155, 190),
        BorderSizePixel = 0,
    }, bar)
    AddCorner(fill, 5)

    local knob = Make("Frame", {
        Size = UDim2.fromOffset(15, 15),
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.new(0, 0, 0.5, 0),
        BackgroundColor3 = Color3.fromRGB(235, 240, 245),
        BorderSizePixel = 0,
    }, bar)
    AddCorner(knob, 8)

    local hitbox = Make("TextButton", {
        Size = UDim2.new(1, 0, 1, 20),
        Position = UDim2.fromOffset(0, -7),
        BackgroundTransparency = 1,
        Text = "",
        AutoButtonColor = false,
    }, bar)

    local value = math.clamp(initial, minValue, maxValue)
    local active = false

    local function SetValueFromX(x)
        local width = math.max(bar.AbsoluteSize.X, 1)
        local alpha = math.clamp(
            (x - bar.AbsolutePosition.X) / width, 0, 1
        )
        value = math.floor(
            minValue + (maxValue - minValue) * alpha + 0.5
        )
        local normalized = (value - minValue) / (maxValue - minValue)
        fill.Size = UDim2.new(normalized, 0, 1, 0)
        knob.Position = UDim2.new(normalized, 0, 0.5, 0)
        valueLabel.Text = tostring(value)
        if callback then callback(value) end
    end

    TrackConnection(hitbox.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            active = true
            SetValueFromX(input.Position.X)
        end
    end))

    TrackConnection(UserInputService.InputChanged:Connect(function(input)
        if active and (
            input.UserInputType == Enum.UserInputType.MouseMovement
            or input.UserInputType == Enum.UserInputType.Touch
        ) then
            SetValueFromX(input.Position.X)
        end
    end))

    TrackConnection(UserInputService.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            active = false
        end
    end))

    task.defer(function()
        local normalized = (value - minValue) / (maxValue - minValue)
        fill.Size = UDim2.new(normalized, 0, 1, 0)
        knob.Position = UDim2.new(normalized, 0, 0.5, 0)
    end)

    titleLabel.Text = title
    return row
end

local function CreateButton(parent, title, callback)
    local button = Make("TextButton", {
        Size = UDim2.new(1, -2, 0, 34),
        BackgroundColor3 = Color3.fromRGB(45, 95, 120),
        Text = title,
        Font = Enum.Font.GothamBold,
        TextSize = 11,
        TextColor3 = Color3.fromRGB(245, 248, 250),
        AutoButtonColor = true,
    }, parent)
    AddCorner(button, 7)
    TrackConnection(button.MouseButton1Click:Connect(callback))
    return button
end

-- PARTE 06 - CONTEÚDO DAS ABAS E LOG VIEWER
CreateSection(AimPage, "TREINAMENTO LOCAL")
CreateToggle(AimPage, "Ativar painel de treinamento", Config.Enabled, function(value)
    Config.Enabled = value
    AddLog("INFO", "Painel de treinamento: " .. (value and "ON" or "OFF"))
end)
CreateToggle(AimPage, "Modo de prática (somente interface)", Config.AimTraining, function(value)
    Config.AimTraining = value
    AddLog("INFO", "Modo de prática: " .. (value and "ON" or "OFF"))
end)
CreateSlider(AimPage, "Suavidade visual", 1, 20, Config.Smoothness, function(value)
    Config.Smoothness = value
end)

CreateSection(FOVPage, "CAMPO DE VISÃO")
CreateToggle(FOVPage, "Mostrar indicador FOV", Config.ShowFOV, function(value)
    Config.ShowFOV = value
    AddLog("INFO", "Indicador FOV: " .. (value and "visível" or "oculto"))
end)
CreateSlider(FOVPage, "Tamanho do indicador", 30, 300, Config.FOV, function(value)
    Config.FOV = value
end)

local FOVIndicator = Make("Frame", {
    Name = "FOVIndicator",
    Size = UDim2.fromOffset(Config.FOV * 2, Config.FOV * 2),
    AnchorPoint = Vector2.new(0.5, 0.5),
    Position = UDim2.fromScale(0.5, 0.5),
    BackgroundTransparency = 1,
    Visible = Config.ShowFOV,
    ZIndex = 10,
}, ScreenGui)
Make("UICorner", {CornerRadius = UDim.new(1, 0)}, FOVIndicator)
Make("UIStroke", {
    Color = Color3.fromRGB(80, 190, 220),
    Thickness = 1.5,
    Transparency = 0.15,
}, FOVIndicator)

CreateSection(VisualPage, "VISUALIZAÇÃO DE TESTE")
CreateToggle(VisualPage, "Mostrar nomes de NPCs de teste", Config.ShowNPCNames, function(value)
    Config.ShowNPCNames = value
    AddLog("INFO", "Preferência de nomes de NPC: " .. tostring(value))
end)
Make("TextLabel", {
    Size = UDim2.new(1, -2, 0, 42),
    BackgroundTransparency = 1,
    Text = "Esta aba guarda preferências visuais. Não marca nem rastreia jogadores.",
    Font = Enum.Font.Gotham,
    TextSize = 11,
    TextWrapped = true,
    TextXAlignment = Enum.TextXAlignment.Left,
    TextColor3 = Color3.fromRGB(155, 165, 175),
}, VisualPage)

CreateSection(ConfigPage, "CONFIGURAÇÕES")
CreateToggle(ConfigPage, "Lembrete de atividade", Config.AntiAFKReminder, function(value)
    Config.AntiAFKReminder = value
    AddLog("INFO", "Lembrete de atividade: " .. tostring(value))
end)
CreateButton(ConfigPage, "RESTAURAR PADRÕES", function()
    Config.Enabled = true
    Config.AimTraining = false
    Config.ShowFOV = true
    Config.FOV = 100
    Config.Smoothness = 5
    Config.ShowNPCNames = false
    Config.AntiAFKReminder = false
    FOVIndicator.Visible = true
    FOVIndicator.Size = UDim2.fromOffset(200, 200)
    AddLog("SUCCESS", "Valores padrão restaurados. Reabra o painel para reaplicar controles.")
end)

CreateSection(LogsPage, "LOG VIEWER")
local LogFrame = Make("Frame", {
    Size = UDim2.new(1, -2, 0, 190),
    BackgroundColor3 = Color3.fromRGB(15, 17, 20),
    BorderSizePixel = 0,
}, LogsPage)
AddCorner(LogFrame, 8)
AddStroke(LogFrame, Color3.fromRGB(55, 65, 75), 1)

local LogScroll = Make("ScrollingFrame", {
    Size = UDim2.new(1, -10, 1, -10),
    Position = UDim2.fromOffset(5, 5),
    BackgroundTransparency = 1,
    BorderSizePixel = 0,
    ScrollBarThickness = 4,
    CanvasSize = UDim2.new(),
    AutomaticCanvasSize = Enum.AutomaticSize.Y,
}, LogFrame)

local LogList = Make("Frame", {
    Size = UDim2.new(1, 0, 0, 0),
    AutomaticSize = Enum.AutomaticSize.Y,
    BackgroundTransparency = 1,
}, LogScroll)

Make("UIListLayout", {
    Padding = UDim.new(0, 3),
    SortOrder = Enum.SortOrder.LayoutOrder,
}, LogList)

local function RefreshLogs()
    for _, child in ipairs(LogList:GetChildren()) do
        if child:IsA("TextLabel") then
            child:Destroy()
        end
    end

    local colors = {
        INFO = Color3.fromRGB(185, 200, 215),
        SUCCESS = Color3.fromRGB(100, 220, 150),
        WARNING = Color3.fromRGB(255, 195, 90),
        ERROR = Color3.fromRGB(255, 110, 110),
    }

    for index, item in ipairs(Logs) do
        Make("TextLabel", {
            Name = "LogEntry",
            Size = UDim2.new(1, -4, 0, 20),
            BackgroundTransparency = 1,
            Text = ("[%s] [%s] %s"):format(
                item.Time, item.Kind, item.Message
            ),
            Font = Enum.Font.Code,
            TextSize = 10,
            TextXAlignment = Enum.TextXAlignment.Left,
            TextColor3 = colors[item.Kind] or colors.INFO,
            TextTruncate = Enum.TextTruncate.AtEnd,
            LayoutOrder = index,
        }, LogList)
    end

    LogScroll.CanvasPosition = Vector2.new(0, 0)
end

_G.GhostRefreshLogs = RefreshLogs

CreateButton(LogsPage, "LIMPAR REGISTROS", function()
    table.clear(Logs)
    RefreshLogs()
    AddLog("SUCCESS", "Registros limpos.")
end)

-- PARTE 07 - INDICADOR E DIAGNÓSTICO
TrackConnection(RunService.RenderStepped:Connect(function()
    if not ScreenGui.Parent then return end
    FOVIndicator.Visible = Config.ShowFOV and Config.Enabled
    local diameter = Config.FOV * 2
    FOVIndicator.Size = UDim2.fromOffset(diameter, diameter)
end))

local function CheckCharacter()
    local character = LocalPlayer.Character
    if not character then
        AddLog("WARNING", "Personagem ainda não carregado.")
        return
    end

    local humanoid = character:FindFirstChildOfClass("Humanoid")
    if humanoid then
        AddLog("SUCCESS", "Personagem carregado.")
        AddLog("INFO", "Vida: " .. math.floor(humanoid.Health))
        AddLog("INFO", "WalkSpeed atual: " .. humanoid.WalkSpeed)
    else
        AddLog("WARNING", "Humanoid não encontrado.")
    end
end

TrackConnection(LocalPlayer.CharacterAdded:Connect(function()
    AddLog("INFO", "Personagem reapareceu.")
    task.wait(1)
    CheckCharacter()
end))

TrackConnection(LocalPlayer.CharacterRemoving:Connect(function()
    AddLog("WARNING", "Personagem está sendo removido.")
end))

TrackConnection(ScreenGui.Destroying:Connect(function()
    for _, connection in ipairs(Connections) do
        if connection.Connected then
            connection:Disconnect()
        end
    end
    if _G.GhostRefreshLogs == RefreshLogs then
        _G.GhostRefreshLogs = nil
    end
end))

AddLog("SUCCESS", "Ghost v3.8 carregado.")
AddLog("INFO", "Interface local pronta.")
CheckCharacter()
