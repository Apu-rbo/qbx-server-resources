local defaultConfig = {
    Debug = false,
    Logs = {
        Enabled = true,
        Service = "discord",
        Avatar = false,
        Dataset = "default",
        Actions = {
            Calls = true,
            Messages = true,
            InstaPic = true,
            Birdy = true,
            YellowPages = true,
            Marketplace = true,
            Mail = true,
            Wallet = true,
            DarkChat = true,
            Services = true,
            Crypto = true,
            Trendy = true,
            Uploads = true
        }
    },
    DatabaseChecker = {
        Enabled = true,
        AutoFix = true
    },
    Framework = "auto",
    CustomFramework = false,
    QBMailEvent = true,
    QBOldJobMethod = false,
    Item = {
        Require = true,
        Name = "phone",
        Unique = false,
        Inventory = "auto"
    },
    ServerSideSpawn = false,
    PropSpawn = "state",
    PhoneModel = 108397254,
    PhoneRotation = vector3(0.0, 0.0, 180.0),
    PhoneOffset = vector3(0.0, -0.005, 0.0),
    DisableOpenNUI = true,
    LiveTray = true,
    SetupScreen = true,
    AutoDisableSparkAccounts = true,
    AutoDeleteNotifications = true,
    MaxNotifications = 50,
    DisabledNotifications = {},
    WhitelistApps = {},
    BlacklistApps = {},
    ChangePassword = {
        Trendy = true,
        InstaPic = true,
        Birdy = true,
        DarkChat = true,
        Mail = true
    },
    DeleteAccount = {
        Trendy = false,
        InstaPic = false,
        Birdy = false,
        DarkChat = false,
        Mail = false,
        Spark = false
    },
    Companies = {
        Enabled = true,
        MessageOffline = true,
        DefaultCallsDisabled = false,
        AllowAnonymous = false,
        SeeEmployees = "everyone",
        DeleteConversations = true,
        AllowNoService = false,
        Services = {
            {
                job = "police",
                name = "Police",
                icon = "https://cdn-icons-png.flaticon.com/512/7211/7211100.png",
                canCall = true,
                canMessage = true,
                bossRanks = { "boss" },
                location = {
                    name = "Mission Row",
                    coords = {
                        x = 428.9,
                        y = -984.5
                    }
                }
            },
            {
                job = "ambulance",
                name = "Ambulance",
                icon = "https://cdn-icons-png.flaticon.com/128/1032/1032989.png",
                canCall = true,
                canMessage = true,
                bossRanks = { "boss", "doctor" },
                location = {
                    name = "Pillbox",
                    coords = {
                        x = 304.2,
                        y = -587.0
                    }
                }
            }
        },
        Contacts = {},
        Management = {
            Enabled = true,
            Duty = true,
            Deposit = true,
            Withdraw = true,
            Hire = true,
            Fire = true,
            Promote = true
        }
    },
    CustomApps = {},
    Valet = {
        Enabled = true,
        VehicleTypes = { "car", "vehicle" },
        Price = 100,
        Model = 1142162924,
        Drive = true,
        DisableDamages = false,
        FixTakeOut = false
    },
    HouseScript = "auto",
    Voice = {
        CallEffects = false,
        SpatialAudio = true,
        SpatialAudioSubmixes = 4,
        System = "auto",
        HearNearby = true,
        RecordNearby = true,
        WaitUntilNotTalking = false
    },
    Sound = {
        Sync = true,
        Networked = false,
        Volume = {
            Multiplier = 1.0,
            Static = false,
            Min = 0.0,
            Max = 1.0
        },
        Ringtones = {
            default = {
                name = "23",
                soundSet = "ringtone"
            },
            ["ringtone 1"] = {
                name = "1",
                soundSet = "ringtone"
            },
            ["ringtone 2"] = {
                name = "7",
                soundSet = "ringtone"
            },
            ["ringtone 3"] = {
                name = "10",
                soundSet = "ringtone"
            },
            ["ringtone 4"] = {
                name = "13",
                soundSet = "ringtone"
            },
            ["ringtone 5"] = {
                name = "15",
                soundSet = "ringtone"
            },
            ["ringtone 6"] = {
                name = "17",
                soundSet = "ringtone"
            },
            ["ringtone 7"] = {
                name = "19",
                soundSet = "ringtone"
            },
            ["ringtone 8"] = {
                name = "21",
                soundSet = "ringtone"
            },
            ["ringtone 9"] = {
                name = "24",
                soundSet = "ringtone"
            }
        },
        Notifications = {
            default = {
                name = "1",
                soundSet = "notification"
            },
            ["notification 1"] = {
                name = "2",
                soundSet = "notification"
            },
            ["notification 2"] = {
                name = "3",
                soundSet = "notification"
            },
            ["notification 3"] = {
                name = "4",
                soundSet = "notification"
            },
            ["notification 4"] = {
                name = "5",
                soundSet = "notification"
            },
            ["notification 5"] = {
                name = "6",
                soundSet = "notification"
            },
            ["notification 6"] = {
                name = "7",
                soundSet = "notification"
            },
            ["notification 7"] = {
                name = "8",
                soundSet = "notification"
            }
        }
    },
    CellTowers = {
        Enabled = true,
        Debug = false,
        MinService = 0,
        Range = {
            [4] = 250.0,
            [3] = 500.0,
            [2] = 750.0,
            [1] = 1500.0
        }
    },
    Locations = {
        {
            position = vector2(428.9, -984.5),
            name = "LSPD",
            description = "Los Santos Police Department",
            icon = "https://cdn-icons-png.flaticon.com/512/7211/7211100.png"
        },
        {
            position = vector2(304.2, -587.0),
            name = "Pillbox",
            description = "Pillbox Medical Hospital",
            icon = "https://cdn-icons-png.flaticon.com/128/1032/1032989.png"
        }
    },
    Locales = {
        {
            locale = "en",
            name = "English"
        },
        {
            locale = "de",
            name = "Deutsch"
        },
        {
            locale = "fr",
            name = "Fran\195\167ais"
        },
        {
            locale = "es",
            name = "Espa\195\177ol"
        },
        {
            locale = "nl",
            name = "Nederlands"
        },
        {
            locale = "dk",
            name = "Dansk"
        },
        {
            locale = "no",
            name = "Norsk"
        },
        {
            locale = "th",
            name = "\224\185\132\224\184\151\224\184\162"
        },
        {
            locale = "ar",
            name = "\216\185\216\177\216\168\217\138"
        },
        {
            locale = "ru",
            name = "\208\160\209\131\209\129\209\129\208\186\208\184\208\185"
        },
        {
            locale = "cs",
            name = "Czech"
        },
        {
            locale = "sv",
            name = "Svenska"
        },
        {
            locale = "pl",
            name = "Polski"
        },
        {
            locale = "hu",
            name = "Magyar"
        },
        {
            locale = "tr",
            name = "T\195\188rk\195\167e"
        },
        {
            locale = "pt-br",
            name = "Portugu\195\170s (Brasil)"
        },
        {
            locale = "pt-pt",
            name = "Portugu\195\170s"
        },
        {
            locale = "it",
            name = "Italiano"
        },
        {
            locale = "ua",
            name = "\208\163\208\186\209\128\208\176\209\151\208\189\209\129\209\140\208\186\176"
        },
        {
            locale = "ba",
            name = "Bosanski"
        },
        {
            locale = "zh-cn",
            name = "\231\174\128\228\189\147\228\184\173\230\150\135 (Chinese Simplified)"
        },
        {
            locale = "ro",
            name = "Romana"
        },
        {
            locale = "ja",
            name = "\230\151\165\230\156\172\232\170\158"
        }
    },
    DefaultLocale = "en",
    DateLocale = "en-US",
    DateFormat = "auto",
    FrameColor = "#39334d",
    AllowFrameColorChange = true,
    PhoneNumber = {
        Format = "({3}) {3}-{4}",
        Length = 7,
        Prefixes = {
            "205",
            "907",
            "480",
            "520",
            "602"
        }
    },
    Battery = {
        Enabled = false,
        ChargeInterval = { 5, 10 },
        DischargeInterval = { 50, 60 },
        DischargeWhenInactiveInterval = { 80, 120 },
        DischargeWhenInactive = true
    },
    CurrencyFormat = "$%s",
    MaxTransferAmount = 1000000,
    TransferOffline = true,
    TransferLimits = {
        Daily = false,
        Weekly = false
    },
    EnableMessagePay = true,
    EnableVoiceMessages = true,
    EnableGIFs = true,
    GIFsFilter = "low",
    CityName = "Los Santos",
    RealTime = true,
    CustomTime = false,
    EmailDomain = "lbscripts.com",
    AutoCreateEmail = false,
    DeleteMail = true,
    ConvertMailToMarkdown = false,
    DeleteMessages = true,
    GroupMessageMemberLimit = false,
    SyncFlash = true,
    EndLiveClose = false,
    AllowExternal = {
        Gallery = false,
        Birdy = false,
        InstaPic = false,
        Spark = false,
        Trendy = false,
        Pages = false,
        Marketplace = false,
        Mail = false,
        Messages = false,
        Other = false
    },
    ExternalBlacklistedDomains = {
        "imgur.com",
        "discord.com",
        "discordapp.com"
    },
    ExternalWhitelistedDomains = {},
    UploadWhitelistedDomains = {
        "fivemanage.com",
        "fmfile.com",
        "cfx.re"
    },
    NameFilter = ".+",
    WordBlacklist = {
        Enabled = false,
        Apps = {
            Birdy = true,
            InstaPic = true,
            Trendy = true,
            Spark = true,
            Messages = true,
            Pages = true,
            Marketplace = true,
            DarkChat = true,
            Mail = true,
            Other = true
        },
        Words = {}
    },
    AutoFollow = {
        Enabled = false,
        Birdy = {
            Enabled = true,
            Accounts = {}
        },
        InstaPic = {
            Enabled = true,
            Accounts = {}
        },
        Trendy = {
            Enabled = true,
            Accounts = {}
        }
    },
    AutoBackup = true,
    Post = {
        Birdy = true,
        InstaPic = true,
        Accounts = {
            Birdy = {
                Username = "Birdy",
                Avatar = "https://assets.loaf-scripts.com/lb-phone/icons/Birdy.png"
            },
            InstaPic = {
                Username = "InstaPic",
                Avatar = "https://assets.loaf-scripts.com/lb-phone/icons/InstaPic.png"
            }
        }
    },
    BirdyTrending = {
        Enabled = true,
        Reset = 168
    },
    BirdyNotifications = false,
    InstaPicLiveNotifications = false,
    PromoteBirdy = {
        Enabled = true,
        Cost = 2500,
        Views = 100
    },
    UsernameFilter = {
        Regex = "[a-zA-Z0-9]+",
        LuaPattern = "^[%w]+$"
    },
    TrendyTTS = {
        { "English (US) - Female", "en_us_001" },
        { "English (US) - Male 1", "en_us_006" },
        { "English (US) - Male 2", "en_us_007" },
        { "English (US) - Male 3", "en_us_009" },
        { "English (US) - Male 4", "en_us_010" },
        { "English (UK) - Male 1", "en_uk_001" },
        { "English (UK) - Male 2", "en_uk_003" },
        { "English (AU) - Female", "en_au_001" },
        { "English (AU) - Male", "en_au_002" },
        { "French - Male 1", "fr_001" },
        { "French - Male 2", "fr_002" },
        { "German - Female", "de_001" },
        { "German - Male", "de_002" },
        { "Spanish - Male", "es_002" },
        { "Spanish (MX) - Male", "es_mx_002" },
        { "Portuguese (BR) - Female 2", "br_003" },
        { "Portuguese (BR) - Female 3", "br_004" },
        { "Portuguese (BR) - Male", "br_005" },
        { "Indonesian - Female", "id_001" },
        { "Japanese - Female 1", "jp_001" },
        { "Japanese - Female 2", "jp_003" },
        { "Japanese - Female 3", "jp_005" },
        { "Japanese - Male", "jp_006" },
        { "Korean - Male 1", "kr_002" },
        { "Korean - Male 2", "kr_004" },
        { "Korean - Female", "kr_003" },
        { "Ghostface (Scream)", "en_us_ghostface" },
        { "Chewbacca (Star Wars)", "en_us_chewbacca" },
        { "C3PO (Star Wars)", "en_us_c3po" },
        { "Stitch (Lilo & Stitch)", "en_us_stitch" },
        { "Stormtrooper (Star Wars)", "en_us_stormtrooper" },
        { "Rocket (Guardians of the Galaxy)", "en_us_rocket" },
        { "Singing - Alto", "en_female_f08_salut_damour" },
        { "Singing - Tenor", "en_male_m03_lobby" },
        { "Singing - Sunshine Soon", "en_male_m03_sunshine_soon" },
        { "Singing - Warmy Breeze", "en_female_f08_warmy_breeze" },
        { "Singing - Glorious", "en_female_ht_f08_glorious" },
        { "Singing - It Goes Up", "en_male_sing_funny_it_goes_up" },
        { "Singing - Chipmunk", "en_male_m2_xhxs_m03_silly" },
        { "Singing - Dramatic", "en_female_ht_f08_wonderful_world" }
    },
    DynamicWebRTC = {
        Enabled = false,
        Service = "cloudflare",
        RemoveStun = false
    },
    Crypto = {
        Enabled = true,
        Refund = false,
        UpdateInterval = 5,
        Coins = {
            lbc = {
                name = "LB Coin",
                icon = "./assets/img/icons/crypto/coins/lbc.webp",
                initialValue = 50.0,
                changes = {
                    {
                        weight = 500,
                        change = { 0.0, 2.0 }
                    },
                    {
                        weight = 490,
                        change = { -2.0, -0.0 }
                    },
                    {
                        weight = 5,
                        change = { 5.0, 15.0 }
                    },
                    {
                        weight = 5,
                        change = { -15.0, -5.0 }
                    }
                },
                permissions = {
                    buy = true,
                    sell = true,
                    transfer = true
                }
            }
        },
        QBit = true,
        Limits = {
            Buy = 1000000,
            Sell = 1000000
        }
    },
    KeyBinds = {
        Open = {
            Command = "phone",
            Bind = "F1",
            Description = "Open your phone"
        },
        Focus = {
            Command = "togglePhoneFocus",
            Bind = "LMENU",
            Description = "Toggle cursor on your phone"
        },
        StopSounds = {
            Command = "stopSounds",
            Bind = false,
            Description = "Stop all phone sounds"
        },
        FlipCamera = {
            Command = "flipCam",
            Bind = "UP",
            Description = "Flip phone camera"
        },
        TakePhoto = {
            Command = "takePhoto",
            Bind = "RETURN",
            Description = "Take a photo / video"
        },
        ToggleFlash = {
            Command = "toggleCameraFlash",
            Bind = "E",
            Description = "Toggle flash"
        },
        LeftMode = {
            Command = "leftMode",
            Bind = "LEFT",
            Description = "Change mode"
        },
        RightMode = {
            Command = "rightMode",
            Bind = "RIGHT",
            Description = "Change mode"
        },
        RollLeft = {
            Command = "cameraRollLeft",
            Bind = "Z",
            Description = "Roll camera to the left"
        },
        RollRight = {
            Command = "cameraRollRight",
            Bind = "C",
            Description = "Roll camera to the right"
        },
        FreezeCamera = {
            Command = "cameraFreeze",
            Bind = "X",
            Description = "Freeze camera"
        },
        AnswerCall = {
            Command = "answerCall",
            Bind = "RETURN",
            Description = "Answer incoming call"
        },
        DeclineCall = {
            Command = "declineCall",
            Bind = "BACK",
            Description = "Decline incoming call"
        },
        UnlockPhone = {
            Bind = "SPACE",
            Description = "Open your phone"
        }
    },
    KeepInput = true,
    DisableFocusTalking = false,
    Camera = {
        ShowTip = true,
        Walkable = true,
        Roll = true,
        AllowRunning = true,
        MaxFOV = 70.0,
        DefaultFOV = 60.0,
        MinFOV = 10.0,
        MaxLookUp = 80.0,
        MaxLookDown = -80.0,
        Vehicle = {
            Zoom = true,
            MaxFOV = 80.0,
            DefaultFOV = 60.0,
            MinFOV = 10.0,
            MaxLookUp = 50.0,
            MaxLookDown = -30.0,
            MaxLeftRight = 120.0,
            MinLeftRight = -120.0
        },
        Selfie = {
            Offset = vector3(0.05, 0.55, 0.6),
            Rotation = vector3(10.0, 0.0, -180.0),
            MaxFov = 90.0,
            DefaultFov = 60.0,
            MinFov = 50.0
        },
        Freeze = {
            Enabled = false,
            MaxDistance = 10.0,
            MaxTime = 60
        }
    },
    UploadMethod = {
        Video = "Fivemanage",
        Image = "Fivemanage",
        Audio = "Fivemanage"
    },
    Video = {
        Bitrate = 400,
        FrameRate = 24,
        MaxSize = 25,
        MaxDuration = 60
    },
    Image = {
        Mime = "image/webp",
        Quality = 0.95
    }
}

local function PrintConfigError(message)
    Citizen.CreateThreadNow(function()
        while true do
            print("^1[ERROR]^7: " .. message)
            Wait(5000)
        end
    end)
end

if not Config then
    PrintConfigError("You've broken the config. Re-install the script, and it will work.")
    Config = defaultConfig
end

for key, value in pairs(defaultConfig) do
    if Config[key] == nil then
        print("^3[WARNING]^7: Missing config key: ^2" .. key .. "^7, using default value.")
        Config[key] = value
    end
end

if #Config.PhoneNumber.Prefixes > 0 then
    local prefixLength = #Config.PhoneNumber.Prefixes[1]

    for i = 1, #Config.PhoneNumber.Prefixes do
        local prefix = Config.PhoneNumber.Prefixes[i]

        if #prefix ~= prefixLength then
            print("^1[ERROR]^7: The phone number prefix ^5" .. prefix .. "^7 is not the same length as the other prefixes.")
        end
    end
end

if Config.Item.Name and Config.Item.Names then
    PrintConfigError("You have both ^2Item.Name^7 and ^2Item.Names^7 in your config. Please remove one of them.")
end

if Config.Item.Unique and not Config.Item.Require then
    PrintConfigError("You have ^2Item.Unique^7 set to true, but ^2Item.Require^7 is set to false. Please set ^2Item.Require^7 to true, or set Item.Unique to false.")
end

CreateThread(function()
    if not UploadMethods then
        print("^3[WARNING]^7: UploadMethods is not defined")
        UploadMethods = {}
    end

    if not Config.UploadMethod then
        PrintConfigError("Config.UploadMethod is not set")
        Config.UploadMethod = {
            Video = "Fivemanage",
            Image = "Fivemanage",
            Audio = "Fivemanage"
        }

        return
    end

    if not Config.UploadMethod.Video then
        PrintConfigError("Config.UploadMethod.Video is not set")
    elseif not UploadMethods[Config.UploadMethod.Video] then
        PrintConfigError("Config.UploadMethod.Video is not set to a valid upload method")
    end

    if not Config.UploadMethod.Image then
        PrintConfigError("Config.UploadMethod.Image is not set")
    elseif not UploadMethods[Config.UploadMethod.Image] then
        PrintConfigError("Config.UploadMethod.Image is not set to a valid upload method")
    end

    if not Config.UploadMethod.Audio then
        PrintConfigError("Config.UploadMethod.Audio is not set")
    elseif not UploadMethods[Config.UploadMethod.Audio] then
        PrintConfigError("Config.UploadMethod.Audio is not set to a valid upload method")
    end
end)
