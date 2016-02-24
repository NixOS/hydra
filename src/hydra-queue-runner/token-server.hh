#pragma once

#include <atomic>

#include "sync.hh"

/* This class hands out tokens. There are only ‘maxTokens’ tokens
   available. Calling get() will return a Token object, representing
   ownership of a token. If no token is available, get() will sleep
   until another thread returns a token. */

class TokenServer
{
    unsigned int maxTokens;

    Sync<unsigned int> curTokens{0};
    std::condition_variable wakeup;

public:
    TokenServer(unsigned int maxTokens) : maxTokens(maxTokens) { }

    class Token
    {
        friend TokenServer;

        TokenServer * ts;

        bool acquired = false;

        Token(TokenServer * ts, unsigned int timeout) : ts(ts)
        {
            auto curTokens(ts->curTokens.lock());
            while (*curTokens >= ts->maxTokens)
                if (timeout) {
                    if (!curTokens.wait_for(ts->wakeup, std::chrono::seconds(timeout),
                            [&]() { return *curTokens < ts->maxTokens; }))
                        return;
                } else
                    curTokens.wait(ts->wakeup);
            (*curTokens)++;
            acquired = true;
        }

    public:

        Token(Token && t) : ts(t.ts) { t.ts = 0; }
        Token(const Token & l) = delete;

        ~Token()
        {
            if (!ts || !acquired) return;
            {
                auto curTokens(ts->curTokens.lock());
                assert(*curTokens);
                (*curTokens)--;
            }
            ts->wakeup.notify_one();
        }

        bool operator ()() { return acquired; }
    };

    Token get(unsigned int timeout = 0)
    {
        return Token(this, timeout);
    }
};
