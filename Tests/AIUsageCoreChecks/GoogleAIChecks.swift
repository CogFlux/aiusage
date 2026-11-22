import AIUsageCore
import Foundation

enum GoogleAIChecks {
    static func run() {
        antigravityQuotaSummaryParsesGroupsAndWindows()
        antigravityQuotaSummarySupportsOneofRemainingAndVersionedGroups()
        antigravityCLIUsageReportParsesSnakeCase()
        antigravityUserStatusExtractsIdentityCreditsAndFallbackGroups()
        antigravityProcessClassificationAndFlags()
        antigravityAlertIDParsing()
        geminiAppParsesXSSIGraphQLResponse()
        geminiAppDetectsAuthFailureAndMalformed()
    }

    static func antigravityQuotaSummaryParsesGroupsAndWindows() {
        let json = """
        {
          "response": {
            "groups": [
              {
                "displayName": "Claude and GPT models",
                "buckets": [
                  {
                    "bucketId": "3p-weekly",
                    "displayName": "Weekly Limit",
                    "window": "weekly",
                    "remaining": { "remainingFraction": 0.65 },
                    "resetTime": "2026-11-28T08:00:00Z"
                  },
                  {
                    "bucketId": "3p-5h",
                    "displayName": "Five Hour Limit",
                    "window": "5h",
                    "remaining": { "remainingFraction": 0.4 },
                    "resetTime": "2026-11-21T20:00:00Z"
                  }
                ]
              },
              {
                "displayName": "Gemini Models",
                "buckets": [
                  {
                    "bucketId": "gemini-5h",
                    "displayName": "Five Hour Limit",
                    "remainingFraction": 0.85,
                    "resetTime": "2026-11-21T19:00:00.000Z"
                  },
                  {
                    "bucketId": "gemini-weekly",
                    "displayName": "Weekly Limit",
                    "remainingFraction": 0.9,
                    "resetTime": "2026-11-28T08:00:00Z"
                  },
                  {
                    "bucketId": "gemini-disabled",
                    "displayName": "Disabled",
                    "disabled": true,
                    "remainingFraction": 0.0,
                    "resetTime": "2026-11-21T19:00:00Z"
                  }
                ]
              }
            ]
          }
        }
        """
        let now = Date(timeIntervalSince1970: 1_795_200_000)
        let usage = try? AntigravityParser.parseQuotaSummary(Data(json.utf8), observedAt: now, source: .app)
        Harness.check(usage != nil, "parses Antigravity quota summary")
        Harness.equal(usage?.groups.map(\.id), ["gemini", "claude-gpt"], "Gemini sorted before Claude / GPT")
        Harness.equal(usage?.groups.map(\.title), ["Gemini", "Claude / GPT"], "group titles normalized")

        let gemini5h = usage?.group("gemini")?.window(.fiveHour)
        let gemini7d = usage?.group("gemini")?.window(.sevenDay)
        let claude5h = usage?.group("claude-gpt")?.window(.fiveHour)
        let claude7d = usage?.group("claude-gpt")?.window(.sevenDay)

        Harness.close(gemini5h?.usedPercent ?? -1, 15, accuracy: 0.01, "Gemini 5h used%")
        Harness.close(gemini7d?.usedPercent ?? -1, 10, accuracy: 0.01, "Gemini 7d used%")
        Harness.close(claude5h?.usedPercent ?? -1, 60, accuracy: 0.01, "Claude/GPT 5h used%")
        Harness.close(claude7d?.usedPercent ?? -1, 35, accuracy: 0.01, "Claude/GPT 7d used%")

        // Representative picks the most constrained group per cadence.
        Harness.close(usage?.representativeWindow(.fiveHour)?.usedPercent ?? -1, 60, accuracy: 0.01, "rep 5h picks highest used")
        Harness.close(usage?.representativeWindow(.sevenDay)?.usedPercent ?? -1, 35, accuracy: 0.01, "rep 7d picks highest used")
        Harness.equal(usage?.limitReached, false, "disabled 0% bucket ignored")
    }

    static func antigravityQuotaSummarySupportsOneofRemainingAndVersionedGroups() {
        let json = """
        {
          "groups": [
            {
              "displayName": "Gemini 4 Argon",
              "buckets": [
                {
                  "bucketId": "gemini-4-argon-weekly",
                  "displayName": "Weekly Limit",
                  "remaining": { "case": "remainingFraction", "value": 0.25 },
                  "resetTime": "2026-11-28T00:00:00Z"
                }
              ]
            }
          ]
        }
        """
        let now = Date(timeIntervalSince1970: 1_795_200_000)
        let usage = try? AntigravityParser.parseQuotaSummary(Data(json.utf8), observedAt: now)
        Harness.equal(usage?.groups.count, 1, "one versioned group")
        Harness.equal(usage?.groups.first?.title, "Gemini 4 Argon", "versioned Gemini keeps its name")
        Harness.equal(usage?.groups.first?.id, "gemini-4-argon", "slugged group id")
        Harness.close(usage?.groups.first?.window(.sevenDay)?.usedPercent ?? -1, 75, accuracy: 0.01, "oneof remaining parsed")
    }

    static func antigravityCLIUsageReportParsesSnakeCase() {
        let json = """
        {
          "status": "SUCCESS",
          "command": {
            "name": "usage",
            "data": {
              "groups": [
                {
                  "display_name": "Gemini Models",
                  "buckets": [
                    {
                      "bucket_id": "gemini-5h",
                      "display_name": "5-Hour",
                      "window": "5h",
                      "remaining_fraction": 0.8,
                      "reset_time": "2026-11-21T21:00:00Z"
                    }
                  ]
                }
              ]
            }
          }
        }
        """
        let now = Date(timeIntervalSince1970: 1_795_200_000)
        let usage = try? AntigravityParser.parseCLIUsageReport(Data(json.utf8), observedAt: now)
        Harness.equal(usage?.source, .cli, "source marked cli")
        Harness.close(usage?.group("gemini")?.window(.fiveHour)?.usedPercent ?? -1, 20, accuracy: 0.01, "snake_case CLI bucket parsed")
    }

    static func antigravityUserStatusExtractsIdentityCreditsAndFallbackGroups() {
        let json = """
        {
          "code": 0,
          "userStatus": {
            "email": "dev@example.com",
            "userTier": { "id": "ultra", "name": "Google AI Ultra" },
            "planStatus": {
              "planInfo": { "planDisplayName": "Pro" },
              "availablePromptCredits": 1200,
              "availableFlowCredits": 450
            },
            "cascadeModelConfigData": {
              "clientModelConfigs": [
                {
                  "label": "Gemini 3.1 Pro (High)",
                  "modelOrAlias": { "model": "gemini-3.1-pro-high" },
                  "quotaInfo": { "remainingFraction": 0.7, "resetTime": "2026-11-22T01:00:00Z" }
                },
                {
                  "label": "Gemini 3.7 Flash",
                  "modelOrAlias": { "model": "gemini-3.7-flash" },
                  "quotaInfo": { "remainingFraction": 0.9, "resetTime": "2026-11-22T01:00:00Z" }
                },
                {
                  "label": "Gemini Flash Lite",
                  "modelOrAlias": { "model": "gemini-flash-lite" },
                  "quotaInfo": { "remainingFraction": 0.0, "resetTime": "2026-11-22T01:00:00Z" }
                },
                {
                  "label": "Claude Sonnet 4.6",
                  "modelOrAlias": { "model": "claude-sonnet-4.6" },
                  "quotaInfo": { "remainingFraction": 0.5, "resetTime": "2026-11-22T03:00:00Z" }
                }
              ]
            }
          }
        }
        """
        let now = Date(timeIntervalSince1970: 1_795_200_000)
        let usage = try? AntigravityParser.parseUserStatus(Data(json.utf8), observedAt: now, source: .ide)
        Harness.equal(usage?.accountEmail, "dev@example.com", "email extracted")
        Harness.equal(usage?.planName, "Google AI Ultra", "userTier.name preferred over planInfo")
        Harness.close(usage?.availablePromptCredits ?? -1, 1200, accuracy: 0.01, "prompt credits extracted")
        Harness.close(usage?.availableFlowCredits ?? -1, 450, accuracy: 0.01, "flow credits extracted")
        Harness.equal(usage?.groups.map(\.id), ["gemini", "claude-gpt"], "both fallback pools created")
        Harness.close(usage?.group("gemini")?.fallbackUsedPercent ?? -1, 30, accuracy: 0.01, "lite ignored, most constrained Gemini kept")
        Harness.close(usage?.group("claude-gpt")?.fallbackUsedPercent ?? -1, 50, accuracy: 0.01, "Claude fallback kept")
        Harness.check(usage?.group("gemini")?.windows.isEmpty == true, "legacy payload does not invent paced 5h duration")
    }

    static func antigravityProcessClassificationAndFlags() {
        let appCmd = "/Applications/Antigravity.app/Contents/Resources/app/language_server_macos_arm --csrf_token tok123 --extension_server_port=45678"
        let geminiAppCmd = "/Applications/Gemini.app/Contents/MacOS/language_server_macos_arm --csrf_token=tok456"
        let ideCmd = "/Applications/Antigravity IDE.app/Contents/Resources/app/extensions/antigravity/bin/language_server_macos --app_data_dir antigravity-ide --csrf_token tok789"
        let unrelated = "/usr/local/bin/language_server_macos --workspace /tmp/foo"

        Harness.equal(AntigravityParser.classifyLanguageServer(commandLine: appCmd), .app, "Antigravity.app is .app")
        Harness.equal(AntigravityParser.classifyLanguageServer(commandLine: geminiAppCmd), .app, "renamed Gemini.app is .app")
        Harness.equal(AntigravityParser.classifyLanguageServer(commandLine: ideCmd), .ide, "Antigravity IDE is .ide")
        Harness.check(AntigravityParser.classifyLanguageServer(commandLine: unrelated) == nil, "unrelated server ignored")

        let args = appCmd.split(separator: " ").map(String.init)
        Harness.equal(AntigravityParser.extractFlag("--csrf_token", from: args), "tok123", "space-separated flag")
        Harness.equal(AntigravityParser.extractFlag("--extension_server_port", from: args), "45678", "equals-separated flag")
    }

    static func antigravityAlertIDParsing() {
        let pace = Pace(usedPercent: 80, elapsedFraction: 0.5, budgetPercent: 50,
                        deltaPercent: 30, projectedPercent: 120, runoutAt: nil, status: .overPace)
        let alert = UsageAlert(kind: .overPace, windowID: "antigravity.claude-gpt.seven_day",
                               resetsAt: Date(), pace: pace)
        Harness.equal(alert.provider, "antigravity", "provider extracted")
        Harness.equal(alert.groupID, "claude-gpt", "group id extracted")
        Harness.equal(alert.rateLimitWindow, WindowKind.sevenDay, "window kind extracted from 3-part id")

        let claudeAlert = UsageAlert(kind: .overPace, windowID: "claude.five_hour",
                                     resetsAt: Date(), pace: pace)
        Harness.equal(claudeAlert.provider, "claude", "2-part provider unchanged")
        Harness.check(claudeAlert.groupID == nil, "2-part id has nil group")
        Harness.equal(claudeAlert.rateLimitWindow, WindowKind.fiveHour, "2-part window kind unchanged")
    }

    static func geminiAppParsesXSSIGraphQLResponse() {
        let body = """
        )]}'
        [
          {
            "data": {
              "viewer": {
                "rpcs": {
                  "getUsageInfo": {
                    "subscriptionTier": "TIER1",
                    "pools": [
                      {
                        "poolType": "GXU_FIVE_HOURLY",
                        "percentageUsed": 0.42,
                        "gxu": { "windowRefreshesAt": "2026-11-21T22:30:00Z" }
                      },
                      {
                        "poolType": "GXU_WEEKLY",
                        "percentageUsed": 0.185,
                        "gxu": { "windowRefreshesAt": "2026-11-27T00:00:00Z" }
                      }
                    ]
                  }
                }
              }
            }
          }
        ]
        """
        let now = Date(timeIntervalSince1970: 1_795_200_000)
        let usage = try? GeminiAppParser.parse(Data(body.utf8), observedAt: now)
        Harness.check(usage != nil, "parses XSSI-prefixed Gemini app GraphQL")
        Harness.equal(usage?.planLabel, "Pro", "TIER1 maps to Pro")
        Harness.close(usage?.window(.fiveHour)?.usedPercent ?? -1, 42, accuracy: 0.01, "5h used%")
        Harness.close(usage?.window(.sevenDay)?.usedPercent ?? -1, 18.5, accuracy: 0.01, "7d used%")
    }

    static func geminiAppDetectsAuthFailureAndMalformed() {
        let now = Date(timeIntervalSince1970: 1_795_200_000)

        let html = "<!doctype html><html>Sign in</html>"
        do {
            _ = try GeminiAppParser.parse(Data(html.utf8), observedAt: now)
            Harness.check(false, "HTML should fail as unauthorized")
        } catch let error as GeminiAppParser.ParseError {
            Harness.equal(error, .unauthorized, "HTML login page maps to unauthorized")
        } catch {
            Harness.check(false, "unexpected error")
        }

        let nullViewer = ")]}'\n[{\"data\":{\"viewer\":null}}]"
        do {
            _ = try GeminiAppParser.parse(Data(nullViewer.utf8), observedAt: now)
            Harness.check(false, "null viewer should fail as unauthorized")
        } catch let error as GeminiAppParser.ParseError {
            Harness.equal(error, .unauthorized, "null viewer maps to unauthorized")
        } catch {
            Harness.check(false, "unexpected error")
        }

        let emptyPools = ")]}'\n[{\"data\":{\"viewer\":{\"rpcs\":{\"getUsageInfo\":{\"pools\":[]}}}}}]"
        do {
            _ = try GeminiAppParser.parse(Data(emptyPools.utf8), observedAt: now)
            Harness.check(false, "empty pools should fail as noWindows")
        } catch let error as GeminiAppParser.ParseError {
            Harness.equal(error, .noWindows, "empty pools maps to noWindows")
        } catch {
            Harness.check(false, "unexpected error")
        }
    }
}
