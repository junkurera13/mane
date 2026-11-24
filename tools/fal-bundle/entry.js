// fal's realtime client for the mirror page (window.FalRealtime).
import { createFalClient } from "@fal-ai/client";
import { wma, lucyRealtime } from "@fal-ai/client/realtime";
window.FalRealtime = { createFalClient, wma, lucyRealtime };
