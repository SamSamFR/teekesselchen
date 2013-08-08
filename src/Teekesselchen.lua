--[[----------------------------------------------------------------------------

    Teekesselchen is a plugin for Adobe Lightroom that finds duplicates by metadata.
    Copyright (C) 2013  Michael Bungenstock

    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program.  If not, see <http://www.gnu.org/licenses/>.
 
--------------------------------------------------------------------------------

Teekesselchen.lua

Provides the logic.

------------------------------------------------------------------------------]]
Teekesselchen ={}

local LrApplication = import "LrApplication"
local LrDialogs = import "LrDialogs"
local LrProgressScope = import "LrProgressScope"
local LrTasks = import "LrTasks"
local LrFileUtils = import "LrFileUtils"

local dummyString = "not a meatbag metadata" -- just be different to any possible real user metadata
local pathPriorities = { {"Trash",-10} , {"memeNom", -20}, {"duplicate", -5}, {"sam_Image", 20} }  -- paths priority scores (higher is better). Default = 0
require "Util"

local function changeOrder(tree,photo)
	-- first element is now rejected
	tree[1]:setRawMetadata("pickStatus", -1)
	-- move the first element to the end
	table.insert(tree, tree[1])
	-- this one is good
	photo:setRawMetadata("pickStatus", 0)
	-- replace first element
	tree[1] = photo
end

local function getNumberFromName(s) -- try to guess the photo number from the filename, like IGP12345, and avoid copy counters like MyCat(1), MyCat(2) ... MyCat(18)
	local list = {}
	s:gsub("(%d%d%d+)", function (x) if #list==0 or #x > #list[1] then list[1]=x end end) -- get the longest number of at least 3 digits
	return list[1]
end


	
local function growTupleMaker(tupleMaker, key, f) -- add function f as additional dimension to the tuple maker
	return function(x)
		keys, t = tupleMaker(x)
		t[key]=f(x)
		table.insert(keys,key)
		return keys, t
	end
end

local function mkTupleMaker(settings)
	local iVC = settings.ignoreVirtualCopies
	local uF = settings.useFlag
	local pRaw = settings.preferRaw
	if pRaw == true then
		pRaw = { ["RAW"]=true, ["DNG"]=true}
	end
	local pL = settings.preferLarge
	local pR = settings.preferRating
	local pP = pathPriorities
	local tupleMaker = nil
	local grow = growTupleMaker
	if uF then
		tupleMaker = function(x) return {}, {} end
		-- deal with raw preference
		if pRaw then
			tupleMaker = grow(tupleMaker, "fileformat", function(photo) return pRaw[photo:getRawMetadata("fileFormat")] end)
		end
		-- deal with file size
		if pL then
			local function getMP(p) -- get MegaPixels count from photo
				local l = {}
				p:getFormattedMetadata("dimensions"):gsub("(%d+)%s*x%s*(%d+)", function (x,y) table.insert(l,x*y*1e-6) end)
				return l[1]
			end
			tupleMaker = grow(tupleMaker, "MPixels", getMP)
			tupleMaker = grow(tupleMaker, "fileSize", function(photo) return photo:getRawMetadata("fileSize") end)
		end
		-- deal with paths priority
		if pP then
			local function pathPrio(photo)
				local path =   photo:getRawMetadata("path")
				local prio = 0
				for i, v in ipairs(pP) do
					pattern = v[1]
					if path:find(pattern) then
						prio = v[2]
					end
				end
				return prio
			end
			tupleMaker = grow(tupleMaker, "pathPriority", pathPrio)
		end
		-- deal with rating
		if pR then
			tupleMaker = grow(tupleMaker, "rating", function(photo) return photo:getRawMetadata("rating") end)
		end
		-- deal with virtual copies
		if not iVC then
			tupleMaker = grow(tupleMaker, "isVirtualCopy", function(photo) return not photo:getRawMetadata("isVirtualCopy") end)
		end
	end
	return tupleMaker
end
local function markDuplicateEnv(tupleMaker, keyword)	
	local function lexComp(keys, x, y) -- lexicographical compare. Return value like the sign of (x-y)
		local function val(x)
			if not x then
				return 0
			elseif type(x)=="boolean" then
				return 1
			else 
				return x
			end
		end
		for i,k in ipairs(keys) do
			if val(x[k]) < val(y[k]) then
				return -1
			elseif val(y[k]) < val(x[k]) then
				return 1
			end
		end
		return 0
	end
	return function(tree, photo)
		if #tree == 0 then
			-- this is easy. just add the photo to the empty list
			table.insert(tree, photo)
			return false
		else
			-- this list is not empty, thus, we have a duplicate!
			-- mark current photo as duplicate
			photo:addKeyword(keyword)
			-- if this is the second element then mark the first element as duplicate, too
			if #tree == 1 then
				tree[1]:addKeyword(keyword)
			end
			if tupleMaker then
				keys, t1 = tupleMaker(tree[1])
				keys, t2 = tupleMaker(photo)
				if lexComp(keys, t1, t2) < 0 then
					changeOrder(tree, photo)
					return true
				end
				-- set the flag
				photo:setRawMetadata("pickStatus", -1)
				-- remove revoke flag if necessary
				if #tree == 1 then
					tree[1]:setRawMetadata("pickStatus", 0)
				end
			end
			table.insert(tree, photo)
			return true
		end
	end
end

local function getExifToolData(settings)
	local parameters = settings.exifToolParameters
  	local doLog = settings.activateLogging
	local cmd = Util.getExifToolCmd(parameters)
	local temp = Util.getTempPath("teekesselchen_exif.tmp")
	local logger = _G.logger
	return function(photo)
		local path = photo:getRawMetadata("path")
		local cmdLine = cmd .. ' "' .. path .. '" > "' .. temp .. '"'
		local value
		if LrTasks.execute(cmdLine) == 0 then
			value = LrFileUtils.readFile(temp)
			if doLog then
				logger:debug("getExifToolData data: " .. value)
			end
		else
			if doLog then
				logger:debug("getExifToolData error for : " .. cmdLine)
			end
		end
    	if not value then value = dummyString end
    	return value
	end
end

local function exifToolEnv(exifTool, marker)
	return function(auxTree, photo)
		if #auxTree == 0 then
			-- this is easy. just add the photo to the empty list
			table.insert(auxTree, photo)
			return false
		else
			local currentMap
			local firstKey
			if #auxTree == 1 then
				local firstPhoto = auxTree[1]
				firstKey = exifTool(firstPhoto)
				-- adds the new map as second element
				currentMap = {}
				currentMap[firstKey] = {firstPhoto}
				table.insert(auxTree, currentMap)
			else
				currentMap = auxTree[2]
			end
			
			local key = exifTool(photo)
			local tree = currentMap[key]
			if not tree then
				currentMap[key] = {photo}
				return false
			end
			return marker(tree, photo)
		end
	end
end

local uniqueID=0
local function mkUniqueID() 
	return function(p)
				uniqueID = uniqueID + 1
				return dummyString .. tostring(uniqueID)
			end
end

local function mkComparatorEnv(functor, fallbackF, comp)
	return function(tree, photo)
		local value = functor(photo)
    	if not value then 
			if fallbackF then 
				value = fallbackF(photo)
			else
				value = dummyString
			end
		end
    	-- does the entry already exists?
    	local sub = tree[value]
		if not sub then
 			sub = {}
   			tree[value] = sub
		end
    	return comp(sub, photo)
	end
end

local function mkComparatorChain(settings, act)
	  	if settings.useExifTool then
	  		act = exifToolEnv(getExifToolData(settings), act)
	  		if doLog then
				logger:debug("findDuplicates: using exifTool")
			end
	  	end
	  	if settings.useCaptureDate then
			local function timeFallback(photo) 
				local val = photo:getFormattedMetadata("dateTimeDigitized")
				if val then return val else return mkUniqueID()(photo) end
			end
			act = mkComparatorEnv( function(p) return p:getFormattedMetadata("dateTimeOriginal")  end, timeFallback, act)
			if doLog then
				logger:debug("findDuplicates: using dateTimeOriginal")
			end
		end
		if true then
			getFilename = function(p) return p:getFormattedMetadata("fileName") end
			act = mkComparatorEnv( function(p) return getNumberFromName(getFilename(p))  end, getFilename, act)
			if doLog then
				logger:debug("findDuplicates: using fileNameNumber")
			end
		end
		if settings.useGPSAltitude then
			act = mkComparatorEnv( function(p) return p:getFormattedMetadata("gpsAltitude")  end, nil, act)
			if doLog then
				logger:debug("findDuplicates: using gpsAltitude")
			end
		end
		if settings.useGPS then
			act = mkComparatorEnv( function(p) return p:getFormattedMetadata("gps")  end, nil, act)
			if doLog then
				logger:debug("findDuplicates: using gps")
			end
		end
		if settings.useExposureBias then
			act = mkComparatorEnv( function(p) return p:getFormattedMetadata("exposureBias")  end, nil, act)
			if doLog then
				logger:debug("findDuplicates: using exposureBias")
			end
		end
		if settings.useAperture then
			act = mkComparatorEnv( function(p) return p:getFormattedMetadata("aperture")  end, nil, act)
			if doLog then
				logger:debug("findDuplicates: using aperture")
			end
		end
		if settings.useShutterSpeed then
			act = mkComparatorEnv( function(p) return p:getFormattedMetadata("shutterSpeed")  end, nil, act)
			if doLog then
				logger:debug("findDuplicates: using shutterSpeed")
			end
		end
		if settings.useIsoRating then
			act = mkComparatorEnv( function(p) return p:getFormattedMetadata("isoSpeedRating")  end, nil, act)
			if doLog then
				logger:debug("findDuplicates: using isoSpeedRating")
			end
		end
		if settings.useLens then
			act = mkComparatorEnv( function(p) return p:getFormattedMetadata("lens")  end, nil, act)
			if doLog then
				logger:debug("findDuplicates: using lens")
			end
		end
		if settings.useSerialNumber then
			act = mkComparatorEnv( function(p) return p:getFormattedMetadata("cameraSerialNumber")  end, nil, act)
			if doLog then
				logger:debug("findDuplicates: using cameraSerialNumber")
			end
		end
		if settings.useModel then
			act = mkComparatorEnv( function(p) return p:getFormattedMetadata("cameraModel")  end, nil, act)
			if doLog then
				logger:debug("findDuplicates: using cameraModel")
			end
		end
		if settings.useMake then
			act = mkComparatorEnv( function(p) return p:getFormattedMetadata("cameraMake")  end, nil, act)
			if doLog then
				logger:debug("findDuplicates: using exposureBias")
			end
		end
		
		if settings.useFileName then
			act = mkComparatorEnv( function(p) return p:getFormattedMetadata("fileName")  end, nil, act)
			if doLog then
				logger:debug("findDuplicates: using fileName")
			end
		end
		
		if settings.useFileSize then
			act = mkComparatorEnv( function(p) return p:getFormattedMetadata("fileSize")  end, nil, act)
			if doLog then
				logger:debug("findDuplicates: using fileSize")
			end
		end
		
		if settings.useFileType then
			act = mkComparatorEnv( function(p) return p:getFormattedMetadata("fileType")  end, nil, act)
			if doLog then
				logger:debug("findDuplicates: using fileType")
			end
		end
	return act
end

function Teekesselchen.new(context)
	local self = {}
	local catalog = LrApplication.activeCatalog()
	local photos = catalog:getMultipleSelectedOrAllPhotos()
	local keywords = {}
	local comperators = {}

	self.total = #photos
	self.skipped = 0
	self.found = 0
	-- create a keyword hash table	
	for i,keyword in ipairs(catalog:getKeywords()) do
		keywords[keyword:getName()] = keyword
	end

	--[[
	This private function takes a string with comma separated keyword names. Returns a
	list of Lightroom keyword objects and a list of not found strings
	]]
	local function getKeywordsForString(str)
		local result = {}
		local keyword
		local notFound = {}
		local j = 1
		
		for i,word in ipairs(Util.split(str)) do
			keyword = keywords[word]
			if keyword then
				result[word] = keyword
				result[j] = keyword
				j = j + 1
			else
				table.insert(notFound, word)
			end
		end
		return result, notFound
	end
	
	--[[
		This public function
	]]
	function self.check_ignoreKeywords(view,value)
		local found, notFound = getKeywordsForString(value)
		if #notFound == 1 then
			return false, value, "Unknown keyword will be ignored: " .. notFound[1]	
		end
		if #notFound > 1 then
			return false, value, "Unknown keywords will be ignored: " .. Util.implode(", ", notFound)
		end
		return true, value
	end
	
	function self.checkKeywordValue(view,value)
		local str = Util.trim(value)
		if string.len(str) == 0 then
			return false, value, "Please provide a keyword"
		end
		return true, value
	end
	
	function self.hasWriteAccess()
		return catalog.hasWriteAccess
	end

	function self.findDuplicates(settings)
  		local logger = _G.logger
  		local doLog = settings.activateLogging
  		if doLog then
  			logger:debug("findDuplicates")
  		end
	  	local ignoreList, _ = getKeywordsForString(settings.ignoreKeywords)
  		local ignoreKeywords = settings.useIgnoreKeywords and (#ignoreList > 0)
  		local ignoreVirtualCopies = settings.ignoreVirtualCopies
  		local keywordObj
  		
  		-- get the keyword and create a smart collection if necessary
  		
  		catalog:withWriteAccessDo("createKeyword", function()
  			if doLog then
	  			logger:debug("Using keyword " .. settings.keywordName .. " as mark")
	  		end
	  		keywordObj = catalog:createKeyword(settings.keywordName, nil, false, nil, true)
  		end)
  		if settings.useSmartCollection then
  			local collection
  			catalog:withWriteAccessDo("createCollection", function()
  				if doLog then
  					logger:debug("Using smart collection " .. settings.smartCollectionName)
  				end
  				collection = catalog:createSmartCollection(settings.smartCollectionName, {
		    		criteria = "keywords",
		    		operation = "words",
		    		value = settings.keywordName,
				}, nil, true)
			end)
			catalog:withWriteAccessDo("cleanCollection", function()
				-- removes the existing photos from the smart collection
				if collection and settings.cleanSmartCollection then
					for i,oldPhoto in ipairs(collection:getPhotos()) do
						if settings.resetFlagSmartCollection and 
						oldPhoto:getRawMetadata("pickStatus") == -1 then
							oldPhoto:setRawMetadata("pickStatus", 0)
						end
						oldPhoto:removeKeyword(keywordObj)
					end
				end			
			end)
	  	end
		-- build the tupleMaker chain (used to order duplicates to pick best / reject the rest)
		local tupleMaker = mkTupleMaker(settings)
		
	  	-- build the comparator chain
	  	local act = markDuplicateEnv(tupleMaker, keywordObj)
		act = mkComparatorChain(settings, act)
  	
  		-- provide a keyword object in current settings
  	
  		local tree = {}
	  	local photo
  		local skip
  		
  		-- local progressScope = LrProgressScope( {title = 'Looking for duplicates ...', functionContext = context, } )
		local progressScope = LrDialogs.showModalProgressDialog({title = 'Looking for duplicates ...', functionContext = context, } )
		local captionTail = " (total: " .. self.total ..")"
  		-- now iterate over all selected photos
		
		local skipCounter = 0
		local duplicateCounter = 0
  		catalog:withWriteAccessDo("findDuplicates", function()
  			for i=1,self.total do
  				-- do the interface stuff at the beginning
  				if progressScope:isCanceled() then
	  				break
  				end
  				progressScope:setPortionComplete(i, self.total)
  				progressScope:setCaption("Checking photo #" .. i .. captionTail)
 	 			LrTasks.yield()
  				-- select the current photo
  				photo = photos[i]
  				if doLog then
  					logger:debugf("Processing photo %s (#%i)", photo:getFormattedMetadata("fileName"), i)
  				end
	  			skip = false
		  		-- skip virtual copies and videos
		  		if (ignoreVirtualCopies and photo:getRawMetadata("isVirtualCopy")) or
  					photo:getRawMetadata("isVideo") then
  					skip = true
	  			else
				-- skip photos with selected keywords, if provided
				if ignoreKeywords then
					for j,keyword in ipairs(photo:getRawMetadata("keywords")) do
						if ignoreList[keyword:getName()] then
							skip = true
							break
						end
					end
				end
			end
			if skip then
				local copyName = photo:getFormattedMetadata("copyName")
				local fileName = photo:getFormattedMetadata("fileName")
				if doLog then
					if copyName then
						logger:debugf(" Skipping %s (Copy %s)", fileName, copyName)
					else
						logger:debugf(" Skipping %s", fileName)
					end
				end
				skipCounter = skipCounter + 1
			else
				if act(tree, photo) then
					duplicateCounter = duplicateCounter + 1
				end
			end
		end
		if doLog then
				logger:debug("findDuplicates: " .. tostring(nbDateLessFiles) .. "dateless files found")
		end
	end)
		progressScope:done()
		self.found = duplicateCounter
		self.skipped = skipCounter
	end
	

	return self
end

