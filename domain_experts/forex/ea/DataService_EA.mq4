//+------------------------------------------------------------------+
//|                                             DataService_EA.mq4 |
//|                         blockcell MT4 Data Service              |
//|  用途：为 blockcell agent 提供实时市场数据 RPC 接口（非交易）      |
//|  协议：ZMQ REQ/REP，端口 5556                                    |
//|  依赖：libzmq.dll, Zmq/Zmq.mqh, JAson.mqh                       |
//+------------------------------------------------------------------+
#property copyright "blockcell contributors"
#property version   "1.1"
#property strict

#include <Zmq/Zmq.mqh>
#include <JAson.mqh>

input int    ZmqPort    = 5556;   // ZMQ 监听端口
input int    TimerMs    = 100;    // 轮询间隔（毫秒），100ms 降低竞态窗口

Context *g_ctx;
Socket  *g_sock;
string   g_endpoint;

//+------------------------------------------------------------------+
int OnInit()
{
    g_endpoint = "tcp://*:" + IntegerToString(ZmqPort);

    g_ctx = new Context();
    if(CheckPointer(g_ctx) == POINTER_INVALID)
    {
        Print("[DataService] ERROR: Failed to create ZMQ context");
        return INIT_FAILED;
    }

    g_sock = new Socket(g_ctx, ZMQ_REP);
    if(CheckPointer(g_sock) == POINTER_INVALID || !g_sock.valid())
    {
        Print("[DataService] ERROR: Failed to create ZMQ socket");
        delete g_ctx;
        return INIT_FAILED;
    }

    // 设置发送/接收超时，避免 send/recv 阻塞 EA 主线程
    g_sock.setLinger(0);

    if(!g_sock.bind(g_endpoint))
    {
        Print("[DataService] ERROR: bind failed — ", Zmq::errorMessage());
        delete g_sock;
        delete g_ctx;
        return INIT_FAILED;
    }

    // 使用毫秒级 timer，降低请求丢失概率
    EventSetMillisecondTimer(TimerMs);

    Print("[DataService] Ready on ", g_endpoint, " (poll interval=", TimerMs, "ms)");
    return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    EventKillTimer();
    if(CheckPointer(g_sock) != POINTER_INVALID)
    {
        g_sock.unbind(g_endpoint);
        delete g_sock;
        g_sock = NULL;
    }
    if(CheckPointer(g_ctx) != POINTER_INVALID)
    {
        delete g_ctx;
        g_ctx = NULL;
    }
    Print("[DataService] Stopped");
}

//+------------------------------------------------------------------+
void OnTick() { /* 空，处理逻辑在 OnTimer */ }

//+------------------------------------------------------------------+
// 核心轮询：每 TimerMs 毫秒检查一次是否有待处理请求
// 使用 drain 循环：一次 timer 触发内处理所有积压请求，避免队列堆积
void OnTimer()
{
    if(CheckPointer(g_sock) == POINTER_INVALID) return;

    ZmqMsg req;
    // drain loop：处理本次 timer 周期内所有积压的请求
    while(g_sock.recv(req, true))  // true = ZMQ_DONTWAIT
    {
        string req_str  = req.getData();
        string response = ProcessRequest(req_str);
        ZmqMsg reply(response);
        // send 也用非阻塞；若对端已断开则跳过，不阻塞 EA
        if(!g_sock.send(reply, true))
            Print("[DataService] WARN: send failed — ", Zmq::errorMessage());
    }
}

//+------------------------------------------------------------------+
string ProcessRequest(string req)
{
    if(req == "PING") return "PONG";

    string parts[];
    int count = StringSplit(req, ':', parts);
    if(count < 1) return "{\"error\":\"empty request\"}";

    string cmd    = parts[0];
    string params = (count > 1) ? parts[1] : "";

    // ----------------------------------------------------------------
    if(cmd == "GET_ACCOUNT_INFO")
    {
        CJAVal j;
        j["balance"] = AccountBalance();
        j["equity"]  = AccountEquity();
        j["margin"]  = AccountMargin();
        j["free_margin"] = AccountFreeMargin();
        j["currency"] = AccountCurrency();
        return j.Serialize();
    }

    // ----------------------------------------------------------------
    if(cmd == "GET_POSITIONS")
    {
        CJAVal arr;
        for(int i = OrdersTotal() - 1; i >= 0; i--)
        {
            if(!OrderSelect(i, SELECT_BY_POS)) continue;
            CJAVal p;
            p["ticket"]     = OrderTicket();
            p["symbol"]     = OrderSymbol();
            p["type"]       = OrderType();
            p["volume"]     = OrderLots();
            p["open_price"] = OrderOpenPrice();
            p["sl"]         = OrderStopLoss();
            p["tp"]         = OrderTakeProfit();
            p["profit"]     = OrderProfit();
            p["swap"]       = OrderSwap();
            p["open_time"]  = (double)OrderOpenTime();
            string cmt = OrderComment();
            StringReplace(cmt, "\\", "\\\\");
            StringReplace(cmt, "\"", "\\\"");
            p["comment"] = cmt;
            arr.Add(p);
        }
        CJAVal r;
        r["positions"] = arr;
        return r.Serialize();
    }

    // ----------------------------------------------------------------
    if(cmd == "GET_INDICATOR")
    {
        // 格式: GET_INDICATOR:RSI,EURUSD,240,14
        string pp[];
        StringSplit(params, ',', pp);
        if(ArraySize(pp) < 3) return "{\"error\":\"insufficient params\"}";

        string name   = pp[0];
        string sym    = pp[1];
        int    tf     = (int)StringToInteger(pp[2]);
        CJAVal j;

        if(name == "RSI")
        {
            if(ArraySize(pp) < 4) return "{\"error\":\"RSI needs period\"}";
            j["value"] = iRSI(sym, tf, (int)StringToInteger(pp[3]), PRICE_CLOSE, 1);
        }
        else if(name == "MACD")
        {
            if(ArraySize(pp) < 6) return "{\"error\":\"MACD needs fast,slow,signal\"}";
            j["main"]   = iMACD(sym, tf, (int)StringToInteger(pp[3]),
                                (int)StringToInteger(pp[4]),
                                (int)StringToInteger(pp[5]), PRICE_CLOSE, MODE_MAIN, 1);
            j["signal"] = iMACD(sym, tf, (int)StringToInteger(pp[3]),
                                (int)StringToInteger(pp[4]),
                                (int)StringToInteger(pp[5]), PRICE_CLOSE, MODE_SIGNAL, 1);
        }
        else if(name == "BB")
        {
            if(ArraySize(pp) < 5) return "{\"error\":\"BB needs period,deviation\"}";
            int    per = (int)StringToInteger(pp[3]);
            double dev = StringToDouble(pp[4]);
            j["middle"] = iBands(sym, tf, per, dev, 0, PRICE_CLOSE, MODE_MAIN,  1);
            j["upper"]  = iBands(sym, tf, per, dev, 0, PRICE_CLOSE, MODE_UPPER, 1);
            j["lower"]  = iBands(sym, tf, per, dev, 0, PRICE_CLOSE, MODE_LOWER, 1);
        }
        else if(name == "ATR")
        {
            if(ArraySize(pp) < 4) return "{\"error\":\"ATR needs period\"}";
            j["value"] = iATR(sym, tf, (int)StringToInteger(pp[3]), 1);
        }
        else if(name == "MA" || name == "SMA")
        {
            if(ArraySize(pp) < 4) return "{\"error\":\"MA needs period\"}";
            j["value"] = iMA(sym, tf, (int)StringToInteger(pp[3]), 0, MODE_SMA, PRICE_CLOSE, 1);
        }
        else if(name == "EMA")
        {
            if(ArraySize(pp) < 4) return "{\"error\":\"EMA needs period\"}";
            j["value"] = iMA(sym, tf, (int)StringToInteger(pp[3]), 0, MODE_EMA, PRICE_CLOSE, 1);
        }
        else if(name == "Stoch")
        {
            if(ArraySize(pp) < 6) return "{\"error\":\"Stoch needs k,d,slowing\"}";
            j["main"]   = iStochastic(sym, tf, (int)StringToInteger(pp[3]),
                                      (int)StringToInteger(pp[4]),
                                      (int)StringToInteger(pp[5]),
                                      MODE_SMA, 0, MODE_MAIN, 1);
            j["signal"] = iStochastic(sym, tf, (int)StringToInteger(pp[3]),
                                      (int)StringToInteger(pp[4]),
                                      (int)StringToInteger(pp[5]),
                                      MODE_SMA, 0, MODE_SIGNAL, 1);
        }
        else
        {
            return "{\"error\":\"unknown indicator: " + name + "\"}";
        }
        return j.Serialize();
    }

    // ----------------------------------------------------------------
    if(cmd == "GET_HISTORICAL_DATA")
    {
        // 格式: GET_HISTORICAL_DATA:EURUSD,240,100
        string pp[];
        StringSplit(params, ',', pp);
        if(ArraySize(pp) < 3) return "{\"error\":\"need symbol,tf,count\"}";

        string sym   = pp[0];
        int    tf    = (int)StringToInteger(pp[1]);
        int    cnt   = (int)StringToInteger(pp[2]);

        MqlRates rates[];
        int copied = CopyRates(sym, tf, 0, cnt, rates);
        if(copied < 0)
            return "{\"error\":\"CopyRates failed: " + IntegerToString(GetLastError()) + "\"}";

        CJAVal arr;
        for(int i = 0; i < copied; i++)
        {
            CJAVal c;
            c["time"]        = (double)rates[i].time;
            c["open"]        = rates[i].open;
            c["high"]        = rates[i].high;
            c["low"]         = rates[i].low;
            c["close"]       = rates[i].close;
            c["tick_volume"] = (double)rates[i].tick_volume;
            arr.Add(c);
        }
        CJAVal r;
        r["symbol"]    = sym;
        r["timeframe"] = tf;
        r["count"]     = copied;
        r["bars"]      = arr;
        return r.Serialize();
    }

    // ----------------------------------------------------------------
    if(cmd == "IS_MARKET_OPEN")
    {
        CJAVal j;
        j["is_open"]       = IsTradeAllowed() && (bool)MarketInfo(Symbol(), MODE_TRADEALLOWED);
        j["trade_allowed"] = IsTradeAllowed();
        j["server_time"]   = (double)TimeCurrent();
        return j.Serialize();
    }

    // ----------------------------------------------------------------
    if(cmd == "GET_SYMBOL_INFO")
    {
        // 格式: GET_SYMBOL_INFO:EURUSD
        string sym = (params != "") ? params : Symbol();
        CJAVal j;
        j["symbol"]  = sym;
        j["bid"]     = SymbolInfoDouble(sym, SYMBOL_BID);
        j["ask"]     = SymbolInfoDouble(sym, SYMBOL_ASK);
        j["spread"]  = (double)SymbolInfoInteger(sym, SYMBOL_SPREAD);
        j["digits"]  = (double)SymbolInfoInteger(sym, SYMBOL_DIGITS);
        j["point"]   = SymbolInfoDouble(sym, SYMBOL_POINT);
        return j.Serialize();
    }

    return "{\"error\":\"unknown command: " + cmd + "\"}";
}
