-- This file is part of the LrMediaWiki project and distributed under the terms
-- of the MIT license (see LICENSE.txt file in the project root directory or
-- [0]).  See [1] for more information about LrMediaWiki.
--
-- Copyright (C) 2014 by the LrMediaWiki team (see CREDITS.txt file in the
-- project root directory or [2])
--
-- [0]  <https://raw.githubusercontent.com/ireas/LrMediaWiki/master/LICENSE.txt>
-- [1]  <https://commons.wikimedia.org/wiki/Commons:LrMediaWiki>
-- [2]  <https://raw.githubusercontent.com/ireas/LrMediaWiki/master/CREDITS.txt>

-- Code status:
-- doc:   partly
-- i18n:  complete

local LrErrors = import 'LrErrors'
local LrHttp = import 'LrHttp'
local LrPathUtils = import 'LrPathUtils'
local LrXml = import 'LrXml'

local JSON = require 'JSON'
local Info = require 'Info'
local MediaWikiUtils = require 'MediaWikiUtils'

local MediaWikiApi = {
	userAgent = string.format('LrMediaWiki %d.%d', Info.VERSION.major, Info.VERSION.minor),
	apiPath = nil,
	githubApiVersion = 'https://api.github.com/repos/robinkrahl/LrMediaWiki/releases',
}

--- URL-encode a string according to RFC 3986.
-- Based on http://lua-users.org/wiki/StringRecipes
-- @param str the string to encode
-- @return the URL-encoded string
function MediaWikiApi.urlEncode(str)
	if str then
		str = string.gsub(str, '\n', '\r\n')
		str = string.gsub (str, '([^%w %-%_%.%~])',
			function(c) return string.format('%%%02X', string.byte(c)) end)
		str = string.gsub(str, ' ', '+')
	end
	return str
end

--- Convert HTTP arguments to a URL-encoded request body.
-- @param arguments (table) the arguments to convert
-- @return (string) a request body created from the URL-encoded arguments
function MediaWikiApi.createRequestBody(arguments)
	local body = nil
	for key, value in pairs(arguments) do
		if body then
			body = body .. '&'
		else
			body = ''
		end
		body = body .. MediaWikiApi.urlEncode(key) .. '=' .. MediaWikiApi.urlEncode(value)
	end
	return body or ''
end

function MediaWikiApi.parseXmlDom(xmlDomInstance)
	local value = nil
	if xmlDomInstance:type() == 'element' then
		value = {}
		for key, attribute in pairs(xmlDomInstance:attributes()) do
			value[key] = attribute.value
		end
		for i = 1, xmlDomInstance:childCount() do
			local child = xmlDomInstance:childAtIndex(i)
			local childName = child:name()
			if childName then
				value[childName] = MediaWikiApi.parseXmlDom(child)
			end
		end
	elseif xmlDomInstance:type() == 'text' then
		value = xmlDomInstance:text()
	end
	return value
end

function MediaWikiApi.performHttpRequest(path, arguments, requestHeaders, post)
	local requestBody = MediaWikiApi.createRequestBody(arguments)

	MediaWikiUtils.trace('Performing HTTP request');
	MediaWikiUtils.trace('Path:')
	MediaWikiUtils.trace(path)
	MediaWikiUtils.trace('Request body:');
	MediaWikiUtils.trace(requestBody);

	local resultBody, resultHeaders
	if post then
		resultBody, resultHeaders = LrHttp.post(path, requestBody, requestHeaders)
	else
		resultBody, resultHeaders = LrHttp.get(path .. '?' .. requestBody, requestHeaders)
	end

	MediaWikiUtils.trace('Result status:');
	MediaWikiUtils.trace(resultHeaders.status);

	if not resultHeaders.status then
		LrErrors.throwUserError(LOC('$$$/LrMediaWiki/Api/NoConnection=No network connection.'))
	elseif resultHeaders.status ~= 200 then
		LrErrors.throwUserError(LOC('$$$/LrMediaWiki/Api/HttpError=Received HTTP status ^1.', resultHeaders.status))
	end

	MediaWikiUtils.trace('Result body:');
	MediaWikiUtils.trace(resultBody);

	return resultBody
end

function MediaWikiApi.performRequest(arguments)
	arguments.format = 'xml'
	local requestHeaders = {
		{
			field = 'User-Agent',
			value = MediaWikiApi.userAgent,
		},
		{
			field = 'Content-Type',
			value = 'application/x-www-form-urlencoded',
		},
	}

	local resultBody = MediaWikiApi.performHttpRequest(MediaWikiApi.apiPath, arguments, requestHeaders, true)
	local resultXml = MediaWikiApi.parseXmlDom(LrXml.parseXml(resultBody))
	if resultXml.error then
		LrErrors.throwUserError(LOC('$$$/LrMediaWiki/Api/MediaWikiError=The MediaWiki error ^1 occured: ^2', resultXml.error.code, resultXml.error.info))
	end
	return resultXml
end

function MediaWikiApi.getCurrentPluginVersion()
	local requestHeaders = {
		{
			field = 'User-Agent',
			value = MediaWikiApi.userAgent,
		},
	}
	local resultBody = MediaWikiApi.performHttpRequest(MediaWikiApi.githubApiVersion, {}, requestHeaders, false)
	local resultJson = JSON:decode(resultBody)
	local firstKey = MediaWikiUtils.getFirstKey(resultJson)
	if firstKey ~= nil then
		return resultJson[firstKey].tag_name
	end
	return nil
end

function MediaWikiApi.login(username, password, token)
	local arguments = {
		action = 'login',
		lgname = username,
		lgpassword = password,
	}
	if token then
		arguments.lgtoken = token
	end
	local xml = MediaWikiApi.performRequest(arguments)

	local loginResult = xml.login.result
	if loginResult == 'Success' then
		return true
	elseif not token and loginResult == 'NeedToken' then
		return MediaWikiApi.login(username, password, xml.login.token)
	end

	return loginResult
end

function MediaWikiApi.getEditToken()
	local arguments = {
		action = 'tokens',
	}
	local xml = MediaWikiApi.performRequest(arguments)
	return xml.tokens.edittoken
end

function MediaWikiApi.appendToPage(page, section, text, comment)
	local arguments = {
		action = 'edit',
		title = page,
		section = 'new',
		sectiontitle = section,
		text = text,
		summary = comment,
		token = MediaWikiApi.getEditToken(),
	}
	MediaWikiApi.performRequest(arguments)
end

function MediaWikiApi.existsFile(fileName)
	local arguments = {
		action = 'query',
		titles = 'File:' .. fileName,
	}
	local xml = MediaWikiApi.performRequest(arguments)
	return xml.query and xml.query.pages and xml.query.pages.page and not xml.query.pages.page.missing
end

function MediaWikiApi.upload(fileName, sourceFilePath, text, comment, ignoreWarnings)
	local sourceFileName = LrPathUtils.leafName(sourceFilePath)

	local arguments = {
		action = 'upload',
		filename = fileName,
		text = text,
		comment = comment,
		token = MediaWikiApi.getEditToken(),
		format = 'xml',
	}
	if ignoreWarnings then
		arguments.ignorewarnings = 'true'
	end
	local requestHeaders = {
		{
			field = 'User-Agent',
			value = MediaWikiApi.userAgent,
		},
	}
	local requestBody = {}
	for key, value in pairs(arguments) do
		requestBody[#requestBody + 1] = {
			name = key,
			value = value,
		}
	end
	requestBody[#requestBody + 1] = {
		name = 'file',
		fileName = sourceFileName,
		filePath = sourceFilePath,
		contentType = 'application/octet-stream',
	}

	local resultBody, resultHeaders = LrHttp.postMultipart(MediaWikiApi.apiPath, requestBody, requestHeaders)

	if resultHeaders.status ~= 200 then
		LrErrors.throwUserError(LOC('$$$/LrMediaWiki/Api/HttpError=Received HTTP status ^1.', resultHeaders.status))
	end

	local resultXml = MediaWikiApi.parseXmlDom(LrXml.parseXml(resultBody))
	if resultXml.error then
		LrErrors.throwUserError(LOC('$$$/LrMediaWiki/Api/MediaWikiError=The MediaWiki error ^1 occured: ^2', resultXml.error.code, resultXml.error.info))
	end

	local uploadResult = resultXml.upload.result
	if uploadResult == 'Success' then
		return true
	elseif uploadResult == 'Warning' then
		local warnings = ''
		-- concatenate the keys of the warnings table (= MediaWiki name of the warning)
		for warning in pairs(resultXml.upload.warnings) do
			if warnings ~= '' then
				warnings = warnings .. ', '
			end
			warnings = warnings .. warning
		end
    return warnings
	else
		return uploadResult
	end
end

return MediaWikiApi
