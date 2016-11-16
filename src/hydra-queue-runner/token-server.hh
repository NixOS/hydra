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
            debug("acquiring %d tokens", tokens);
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

        Token(Token && t) : ts(t.ts), tokens(t.tokens), acquired(t.acquired)
        {
            t.ts = 0;
            t.acquired = false;
        }
        Token(const Token & l) = delete;

        ~Token()
        {
            if (!ts || !acquired) return;
            give_back(tokens);
        }

        bool operator ()() { return acquired; }

        void give_back(size_t t)
        {
            debug("returning %d tokens", t);
            if (!t) return;
            assert(acquired);
            assert(t <= tokens);
            {
                auto inUse(ts->inUse.lock());
                assert(*inUse >= t);
                *inUse -= t;
                tokens -= t;
            }
            // FIXME: inefficient. Should wake up waiters that can
            // proceed now.
            ts->wakeup.notify_all();
        }

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
