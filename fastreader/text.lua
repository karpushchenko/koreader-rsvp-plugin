-- Extract visible words from crengine and paged document providers.
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("gettext")
local Text = {}

function Text:extractWordsFromCurrentPage()
    if not self.ui.document then
        logger.warn("FastReader: No document available")
        return {}
    end

    local text = ""
    local debug_info = {}

    logger.info("FastReader: Starting text extraction")
    logger.info("FastReader: Document type: " .. tostring(self.ui.document.provider))

    if self.ui.rolling then
        -- For reflowable documents (EPUB, FB2, etc.)
        -- Use the same method as readerview.lua getCurrentPageLineWordCounts()
        logger.info("FastReader: Rolling document - using getTextFromPositions")

        local success, text_result = pcall(function()
            local Screen = require("device").screen
            local res = self.ui.document:getTextFromPositions(
                {x = 0, y = 0},
                {x = Screen:getWidth(), y = Screen:getHeight()},
                true -- do not highlight
            )

            if res and res.text then
                logger.info("FastReader: getTextFromPositions success: " .. string.len(res.text) .. " characters")
                return res.text
            else
                logger.warn("FastReader: getTextFromPositions returned empty result")
                return nil
            end
        end)

        if success and text_result and text_result ~= "" then
            text = text_result
            table.insert(debug_info, "SUCCESS: getTextFromPositions returned " .. string.len(text_result) .. " chars")
            logger.info("FastReader: Text extraction success: " .. string.len(text_result) .. " characters")
        else
            table.insert(debug_info, "FAILED: getTextFromPositions - " .. tostring(text_result))
            logger.warn("FastReader: getTextFromPositions failed: " .. tostring(text_result))

            -- Fallback: try to get text from XPointers
            local fallback_success, fallback_text = pcall(function()
                -- For rolling documents, try XPointer method
                if self.ui.rolling and self.ui.document.getTextFromXPointers then
                    local current_xpointer = self.ui.rolling:getBookLocation()
                    if current_xpointer then
                        -- This API returns a string; its flag enables drawing
                        -- a selection (unlike getTextFromPositions).
                        local xpointer_text = self.ui.document:getTextFromXPointers(
                            current_xpointer, current_xpointer, false)
                        if type(xpointer_text) == "string" and xpointer_text ~= "" then
                            return xpointer_text
                        end
                    end
                end
                return nil
            end)

            if fallback_success and fallback_text and fallback_text ~= "" then
                text = fallback_text
                table.insert(debug_info, "SUCCESS: XPointer fallback returned " .. string.len(fallback_text) .. " chars")
                logger.info("FastReader: XPointer fallback success: " .. string.len(fallback_text) .. " characters")
            else
                table.insert(debug_info, "FAILED: XPointer fallback - " .. tostring(fallback_text))
                logger.warn("FastReader: XPointer fallback failed: " .. tostring(fallback_text))
            end
        end

    elseif self.ui.paging then
        -- For paged documents (PDF, DjVu, etc.)
        local page = self.ui.paging.current_page
        table.insert(debug_info, "Document type: paging (PDF/DjVu/etc), page: " .. tostring(page))
        logger.info("FastReader: Paging document, page: " .. tostring(page))

        if page and self.ui.document.getPageText then
            local success, page_text = pcall(self.ui.document.getPageText, self.ui.document, page)
            if success and type(page_text) == "table" then
                -- MuPDF returns lines of word boxes, with geometry alongside
                -- the array entries. Keep their order and ignore that metadata.
                local page_words = {}
                for _, line in ipairs(page_text) do
                    for _, word_box in ipairs(line) do
                        if word_box.word then
                            table.insert(page_words, word_box.word)
                        end
                    end
                end
                page_text = table.concat(page_words, " ")
            end
            if success and page_text and page_text ~= "" then
                text = page_text
                table.insert(debug_info, "SUCCESS: getPageText returned " .. string.len(page_text) .. " chars")
                logger.info("FastReader: Successfully extracted " .. string.len(page_text) .. " characters")
            else
                table.insert(debug_info, "FAILED: getPageText - " .. tostring(page_text))
                logger.warn("FastReader: getPageText failed: " .. tostring(page_text))
            end
        end
    else
        table.insert(debug_info, "ERROR: Unknown document type - neither rolling nor paging")
        logger.warn("FastReader: Unknown document type")
    end

    logger.info("FastReader: Final text extraction result: " .. (text and string.len(text) or 0) .. " characters")

    -- Show debug info if no text was found
    if not text or text == "" then
        logger.warn("FastReader: Text extraction completely failed")
        logger.info("FastReader: Debug info: " .. table.concat(debug_info, " | "))

        UIManager:show(InfoMessage:new{
            text = _("Cannot extract text from this document type"),
            timeout = 3,
        })

        return {}
    end

    -- Split text into words, removing punctuation and extra spaces
    local words = {}
    for word in text:gmatch("%S+") do
        -- Clean up word (remove some punctuation but keep basic structure)
        word = word:gsub("^[%p]*", ""):gsub("[%p]*$", "")
        if word and word ~= "" then
            table.insert(words, word)
        end
    end

    logger.info("FastReader: Successfully extracted " .. #words .. " words")
    return words
end

return Text
