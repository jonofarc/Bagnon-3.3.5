
--[[
    sorting.lua
    Client side bag sorting algorithm.
    Supports regular bags and Guild Bank tabs.
    Preserves the Non-Cleanable Slots feature.
--]]

local Sort = Bagnon:NewModule('Sorting', 'AceTimer-3.0')
Bagnon.Sorting = Sort

Sort.Proprieties = {
  'class', 'subclass',
  'quality',
  'icon',
  'level', 'name', 'id',
  'count'
}

Sort.init = false
Sort.isGuildBank = false

--[[ Initialization ]]--

function Sort:Init()
  if self.init then
    return
  end

  self.init = true
  self.Classes = {}

  for i, itemClass in ipairs({GetAuctionItemClasses()}) do
    local subClasses = {}

    for j, subClass in ipairs({GetAuctionItemSubClasses(i)}) do
      subClasses[subClass] = j
    end

    self.Classes[itemClass] = {
      index = i,
      subClasses = subClasses
    }
  end
end

--[[ Process ]]--

function Sort:Start(itemFrame)
  if not self:CanRun() then
    return
  end

  if not itemFrame then
    return
  end

  -- Regular Bagnon item frames expose GetVisibleBags().
  -- Guild Bank item frames expose GetCurrentTab() instead.
  if type(itemFrame.GetVisibleBags) == 'function' then
    self.isGuildBank = false
  elseif type(itemFrame.GetCurrentTab) == 'function'
  and type(itemFrame.GetCurrentTabSize) == 'function'
  and type(itemFrame.GetItemSlot) == 'function' then
    self.isGuildBank = true
  else
    if itemFrame.SendMessage then
      itemFrame:SendMessage('SORTING_STATUS')
    end
    return
  end

  self:Init()
  self.itemFrame = itemFrame

  -- A Guild Bank must have a selected tab.
  if self.isGuildBank then
    local tab = itemFrame:GetCurrentTab()

    if not tab or tab < 1 then
      self:Stop()
      return
    end
  end

  self:Run()
end

function Sort:Run()
  if not self:CanRun() then
    self:Stop()
    return
  end

  if not self.itemFrame then
    return
  end

  ClearCursor()
  self:Iterate()
end

function Sort:Iterate()
  local spaces = self:GetSpaces()

  if not spaces or #spaces == 0 then
    self:Stop()
    return
  end

  local families = self:GetFamilies(spaces)
  local updateRequired = false

  local function stackable(item)
    return item
    and item.id
    and (item.count or 1) < (item.stack or 1)
  end

  -- Stack matching items first.
  -- Protected slots are never used as a source or target.
  for k, target in ipairs(spaces) do
    local item = target.item

    if target.cleanable and stackable(item) then
      for j = k + 1, #spaces do
        local from = spaces[j]
        local other = from.item

        if from.cleanable
        and not from.locked
        and not target.locked
        and other
        and item.id == other.id
        and stackable(other) then

          if self:Move(from, target) then
            updateRequired = true
          end
        end
      end
    end
  end

  local function moveDistance(item, goal)
    return math.abs(item.space.index - goal.index)
  end

  -- Sort items within each compatible bag family.
  for _, family in ipairs(families) do
    local order, familySpaces = self:GetOrder(spaces, family)
    local n = min(#order, #familySpaces)

    for index = 1, n do
      local goal = familySpaces[index]
      local item = order[index]

      item.sorted = true

      if item.space ~= goal then
        local distance = moveDistance(item, goal)

        -- Prefer moving the matching item from farther away.
        for j = index, n do
          local other = order[j]

          if other.id == item.id
          and other.count == item.count then

            local d = moveDistance(other, familySpaces[j])

            if d > distance then
              item = other
              distance = d
            end
          end
        end

        if self:Move(item.space, goal) then
          updateRequired = true
        end
      end
    end
  end

  if updateRequired then
    self:ScheduleTimer('Run', 0.15)
  else
    self:Stop()
  end
end

function Sort:Stop()
  if self.itemFrame and self.itemFrame.SendMessage then
    self.itemFrame:SendMessage('SORTING_STATUS')
  end
end

--[[ Non-Cleanable Slots ]]--

function Sort:GetNonCleanableSlots()
  if not self.itemFrame then
    return 0
  end

  local frameSettings

  if self.itemFrame.GetSettings then
    frameSettings = self.itemFrame:GetSettings()
  end

  if frameSettings and frameSettings.GetNonCleanableSlots then
    return frameSettings:GetNonCleanableSlots() or 0
  end

  if self.itemFrame.GetFrameID then
    frameSettings = Bagnon.FrameSettings:Get(
      self.itemFrame:GetFrameID()
    )

    if frameSettings and frameSettings.GetNonCleanableSlots then
      return frameSettings:GetNonCleanableSlots() or 0
    end
  end

  if self.itemFrame.GetID then
    frameSettings = Bagnon.FrameSettings:Get(
      self.itemFrame:GetID()
    )

    if frameSettings and frameSettings.GetNonCleanableSlots then
      return frameSettings:GetNonCleanableSlots() or 0
    end
  end

  return 0
end

function Sort:IsCleanableSpace(space)
  return space and space.cleanable
end

--[[ Item Data ]]--

function Sort:GetItemData(link, texture, count, locked, quality)
  local item = {
    count = count or 0,
    locked = locked or false,
    quality = 0,
    icon = texture or '',
    class = 0,
    subclass = 0,
    level = 0,
    name = '',
    id = 0,
    stack = 1
  }

  if not link then
    return item
  end

  local name, itemLink, rarity, itemLevel, itemMinLevel,
  itemType, itemSubType, itemStackCount = GetItemInfo(link)

  item.class = self.Classes[itemType]
  and self.Classes[itemType].index or 0

  item.subclass = self.Classes[itemType]
  and self.Classes[itemType].subClasses[itemSubType] or 0

  item.stack = itemStackCount or 1
  item.id = tonumber(link:match('item:(%d+)')) or 0
  item.quality = quality or rarity or 0
  item.level = itemLevel or 0
  item.name = name or link
  item.count = count or 0
  item.locked = locked or false

  return item
end

--[[ Data Structures ]]--

function Sort:GetSpaces()
  if self.isGuildBank then
    return self:GetGuildBankSpaces()
  end

  return self:GetBagSpaces()
end

--[[ Regular Bags ]]--

function Sort:GetBagSpaces()
  local spaces = {}
  local itemFrame = self.itemFrame

  for _, bag in itemFrame:GetVisibleBags() do
    local family = Bagnon.BagSlotInfo:GetBagType(
      itemFrame:GetPlayer(),
      bag
    )

    for slot = 1, itemFrame:GetBagSize(bag) do
      local itemSlot = itemFrame:GetItemSlot(bag, slot)

      if itemSlot then
        local texture, count, locked, quality,
        readable, lootable, link =
            itemSlot:GetItemSlotInfo()

        local space = {
          index = #spaces,
          bag = bag,
          slot = slot,
          family = family or 0,
          locked = locked or false,
          cleanable = true
        }

        space.item = self:GetItemData(
          link, texture, count, locked, quality
        )
        space.item.space = space

        tinsert(spaces, space)
        space.index = #spaces
      end
    end
  end

  self:ApplyNonCleanableSlots(spaces)

  return spaces
end

--[[ Guild Bank ]]--

function Sort:GetGuildBankSpaces()
  local spaces = {}
  local itemFrame = self.itemFrame
  local tab = itemFrame:GetCurrentTab()
  local slotCount = itemFrame:GetCurrentTabSize()

  if not tab or tab < 1 or not slotCount or slotCount < 1 then
    return spaces
  end

  -- The Guild Bank item frame reports 98 slots per tab.
  -- Read only the currently selected tab.
  for slot = 1, slotCount do
    local itemSlot = itemFrame:GetItemSlot(slot)

    local texture, count, locked, link

    if itemSlot and itemSlot.GetItemSlotInfo then
      texture, count, locked, link =
          itemSlot:GetItemSlotInfo()
    else
      texture, count, locked = GetGuildBankItemInfo(tab, slot)
      link = GetGuildBankItemLink(tab, slot)
    end

    local space = {
      index = #spaces + 1,
      tab = tab,
      slot = slot,
      bag = tab,
      family = 0,
      locked = locked or false,
      cleanable = true
    }

    local quality

    if link then
      quality = select(3, GetItemInfo(link))
    end

    space.item = self:GetItemData(
      link, texture, count, locked, quality
    )

    space.item.space = space

    tinsert(spaces, space)
  end

  self:ApplyNonCleanableSlots(spaces)

  return spaces
end

function Sort:ApplyNonCleanableSlots(spaces)
  local nonCleanableSlots = tonumber(
    self:GetNonCleanableSlots()
  ) or 0

  nonCleanableSlots = max(0, min(
    math.floor(nonCleanableSlots),
    #spaces
  ))

  local firstProtectedIndex = #spaces - nonCleanableSlots + 1

  for index, space in ipairs(spaces) do
    space.cleanable = index < firstProtectedIndex
  end
end

--[[ Families ]]--

function Sort:GetFamilies(spaces)
  local set = {}

  for _, space in ipairs(spaces) do
    if space.cleanable then
      set[space.family] = true
    end
  end

  local list = {}

  for family in pairs(set) do
    tinsert(list, family)
  end

  sort(list, function(a, b)
    return a > b
  end)

  return list
end

function Sort:GetOrder(spaces, family)
  local order, slots = {}, {}

  for _, space in ipairs(spaces) do
    local item = space.item

    if space.cleanable
    and not space.locked
    and item.id
    and item.id > 0
    and not item.sorted
    and self:FitsIn(item.id, family) then

      tinsert(order, item)
    end

    if space.cleanable
    and not space.locked
    and space.family == family then

      tinsert(slots, space)
    end
  end

  sort(order, self.Rule)

  return order, slots
end

--[[ Rules ]]--

function Sort:CanRun()
  return not InCombatLockdown() and not UnitIsDead('player')
end

function Sort:FitsIn(id, family)
  if family == 9 then
    return GetItemFamily(id) == 256
  end

  return family == 0
  or (
  bit.band(GetItemFamily(id), family) > 0
  and select(9, GetItemInfo(id)) ~= 'INVTYPE_BAG'
  )
end

function Sort.Rule(a, b)
  for _, prop in ipairs(Sort.Proprieties) do
    local av = a[prop]
    local bv = b[prop]

    if av ~= bv then
      if av == nil then
        return false
      elseif bv == nil then
        return true
      end

      return av > bv
    end
  end

  if a.space.family ~= b.space.family then
    return a.space.family > b.space.family
  end

  return a.space.index < b.space.index
end

--[[ Movement ]]--

function Sort:Move(from, to)
  if not from or not to then
    return false
  end

  -- Never move items into or out of protected slots.
  if not from.cleanable or not to.cleanable then
    return false
  end

  if from.locked or to.locked then
    return false
  end

  if not from.item or not from.item.id or from.item.id == 0 then
    return false
  end

  if to.item and to.item.id
  and to.item.id > 0
  and not self:FitsIn(to.item.id, from.family) then
    return false
  end

  ClearCursor()

  if self.isGuildBank then
  -- Both spaces must belong to the same selected tab.
    if not from.tab or not to.tab or from.tab ~= to.tab then
      return false
    end

    -- Guild Bank API requires (tab, slot).
    PickupGuildBankItem(from.tab, from.slot)
    PickupGuildBankItem(to.tab, to.slot)
  else
  -- Regular bag API requires (bag, slot).
    PickupContainerItem(from.bag, from.slot)
    PickupContainerItem(to.bag, to.slot)
  end

  ClearCursor()

  -- Avoid attempting to reuse these stale space objects.
  -- The next scheduled pass rereads the actual slots.
  from.locked = true
  to.locked = true

  return true
end
