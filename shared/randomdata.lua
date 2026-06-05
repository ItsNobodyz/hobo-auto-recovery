RandomData = {}

RandomData.FirstNames = {
  'Michael','Trevor','Franklin','Amanda','Tracy','Wade','Ron','Lamar','Simeon','Martin',
  'Dave','Steve','Lester','Jimmy','Floyd','Wei','Huang','Niko','Roman','Johnny',
  'Clay','Terry','Ashley','Tao','Lazlow','Solomon','Patricia','Mary-Ann','Denise','Tonya',
  'Barry','Stretch','Harold','Gerald','Chef','Gustavo','Isiah','Leo','Vasquez','Pedro',
  'Hector','Ortega','Kenny','Leon','Chan','Carlos','Diego','Maria','Elena','Sofia',
  'James','Robert','John','William','Richard','Joseph','Thomas','Charles','Daniel','Matthew',
}

RandomData.LastNames = {
  'Johnson','Clinton','De Santa','Townley','Stone','Phillips','Perkins','Davis','Chen','Edwards',
  'Kim','Rodriguez','Park','Martinez','Thompson','Williams','Brown','Jones','Garcia','Miller',
  'Wilson','Moore','Taylor','Anderson','Thomas','Jackson','White','Harris','Martin','Lewis',
  'Lee','Walker','Hall','Allen','Young','Hernandez','King','Wright','Lopez','Hill',
  'Scott','Green','Adams','Baker','Gonzalez','Nelson','Carter','Mitchell','Perez','Roberts',
  'Turner','Phillips','Campbell','Parker','Evans','Edwards','Collins','Stewart','Sanchez','Morris',
}

RandomData.Banks = {
  'Maze Bank',
  'Pacific Standard Bank',
  'Fleeca Bank',
  'Bilge-Water Savings',
  'Bobcat Credit Union',
  'Merryweather Finance',
  'Lombank',
  'FIB Federal Credit Union',
  'Gruppe 6 Lending',
  'Vangelico Credit',
  'Rockford Credit Union',
  'Strawberry Savings & Loan',
}

RandomData.Reasons = {
  '3 missed payments',
  '5 months delinquent',
  '7 missed payments',
  '6 months past due — final notice',
  'No payments in 4 months',
  '4 consecutive missed payments',
  'Account referred to collections',
  '8 months delinquent',
  'Account charged off — recovery required',
  '12 weeks past due',
  'Disputed ownership — lender hold',
  'Voluntary surrender requested by lienholder',
  '9 months with zero contact',
  'Loan default — repossession authorized',
}

-- FiveM primary vehicle color index → color name string
local COLOR_MAP = {
  [0]  = 'Black',        [1]  = 'Carbon Black',    [2]  = 'Graphite',
  [3]  = 'Anthracite',   [4]  = 'Black Steel',      [5]  = 'Dark Steel',
  [6]  = 'Silver',       [7]  = 'Bluish Silver',    [8]  = 'Rolled Steel',
  [9]  = 'Shadow Silver',[10] = 'Stone Silver',     [11] = 'Midnight Silver',
  [12] = 'Cast Iron',    [27] = 'Red',              [28] = 'Torino Red',
  [29] = 'Formula Red',  [30] = 'Lava Red',         [31] = 'Blaze Red',
  [32] = 'Grace Red',    [33] = 'Garnet Red',       [34] = 'Sunset Red',
  [49] = 'White',        [50] = 'Frost White',      [51] = 'Cream White',
  [63] = 'Royal Blue',   [64] = 'Dark Blue',        [65] = 'Ocean Blue',
  [66] = 'Night Blue',   [67] = 'Midnight Blue',    [68] = 'Cobalt Blue',
  [70] = 'Mariner Blue', [71] = 'Harbor Blue',      [72] = 'Diamond Blue',
  [86] = 'Yellow',       [89] = 'Race Yellow',      [90] = 'Dune Yellow',
  [96] = 'Green',        [97] = 'Dark Green',       [98] = 'Sea Green',
  [99] = 'Olive Green',  [109]= 'Orange',           [110]= 'Bright Orange',
  [111]= 'Burnt Orange', [118]= 'Maroon',           [122]= 'Purple',
  [123]= 'Midnight Purple',[136]='Dark Brown',      [137]='Bronze',
}

function RandomData.GetColorName(colorIndex)
  return COLOR_MAP[colorIndex] or 'Custom'
end

function RandomData.RandomName()
  local fn = RandomData.FirstNames[math.random(#RandomData.FirstNames)]
  local ln = RandomData.LastNames[math.random(#RandomData.LastNames)]
  return fn .. ' ' .. ln
end

function RandomData.RandomBank()
  return RandomData.Banks[math.random(#RandomData.Banks)]
end

function RandomData.RandomReason()
  return RandomData.Reasons[math.random(#RandomData.Reasons)]
end

-- Returns a random amount owed between $5,000 and $45,000
function RandomData.RandomAmount()
  return math.random(5, 45) * 1000
end

-- Returns a random operator reward between $1,500 and $5,000
function RandomData.RandomReward()
  return math.random(3, 10) * 500
end
