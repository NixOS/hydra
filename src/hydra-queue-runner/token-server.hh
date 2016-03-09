#pragma once

#include <atomic>

#include "sync.hh"
#include "types.hh"

namespace nix {

MakeError(NoTokens, Error)

/* This class hands out tokens. There are only ‘maxTokens’ tokens
   available. Calling get(N) will return a Token object, representing
   ownership of N tokens. If the requested number of tokens is
   unavailable, get() will sleep until another thread returns a
   token. */

class TokenServer
{
    const size_t maxTokens;

    Sync<size_t> inUse{0};
    std::condition_variable wakeup;

public:
    TokenServer(size_t maxTokens) : maxTokens(maxTokens) { }

    class Token
    {
        friend TokenServer;

        TokenServer * ts;

        size_t tokens;

        bool acquired = false;

        Token(TokenServer * ts, size_t tokens, unsigned int timeout)
            : ts(ts), tokens(tokens)
        {
            if (tokens >= ts->maxTokens)
                throw NoTokens(format("requesting more tokens (%d) than exist (%d)") % tokens % ts->maxTokens);
            auto inUse(ts->inUse.lock());
            while (*inUse + tokens > ts->maxTokens)
                if (timeout) {
                    if (!inUse.wait_for(ts->wakeup, std::chrono::seconds(timeout),
                            [&]() { return *inUse + tokens <= ts->maxTokens; }))
                        return;
                } else
                    inUse.wait(ts->wakeup);
            *inUse += tokens;
            acquired = true;
        }

    public:

        Token(Token && t) : ts(t.ts) { t.ts = 0; }
        Token(const Token & l) = delete;

        ~Token()
        {
            if (!ts || !acquired) return;
            {
                auto inUse(ts->inUse.lock());
                assert(*inUse >= tokens);
                *inUse -= tokens;
            }
            ts->wakeup.notify_one();
        }

        bool operator ()() { return acquired; }
    };

    Token get(size_t tokens = 1, unsigned int timeout = 0)
    {
        return Token(this, tokens, timeout);
    }

    size_t currentUse()
    {
        auto inUse_(inUse.lock());
        return *inUse_;
    }
};

}
