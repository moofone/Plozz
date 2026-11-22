import Foundation

/// Place names that can stand for a regional channel feed, with the canonical name shown to people ("Montreal" is shown as "Montréal").
/// One `term|Canonical name|type` per line; type `s` is a state or province, `m` a metropolitan area that covers the city next to it,
/// `p` any other place. Sources (public lists, nothing taken from provider data): Canadian census metropolitan areas, CRTC broadcast
/// markets and provinces; the Nielsen designated market areas (210) and their principal cities; US states; the cities of licence of US
/// television stations (Wikipedia, "List of television stations in the United States by call sign"); feed words (East, West, Pacific).
/// Also a few provider abbreviations of a place ("CB-Yukon") and misspellings seen in the export ("Mt Verno").
enum LiveTVPlaceNames {
    /// The canonical places that can tag a channel (states, provinces, metropolitan areas and cities, not the feed words), sorted.
    static let tagPlaces: [String] = {
        var places = Set<String>()
        for line in table.split(separator: "\n") {
            let parts = line.split(separator: "|")
            if parts.count == 3, parts[2] != "f" { places.insert(String(parts[1])) }
        }
        // Two spellings of one place ("Tri State", "Tri-State") are one tag; the first in sorted order is its title.
        var seen = Set<String>()
        return places.sorted().filter { seen.insert(LiveTVFilterTagCatalog.regionTagID($0)).inserted }
    }()

    static let table = """
CB|British Columbia|s
NY|New York|s
Ft Worth|Fort Worth|p
Ft Myers|Fort Myers|p
New York|New York|p
Los Angeles|Los Angeles|p
Chicago|Chicago|p
Dallas|Dallas|p
Fort Worth|Fort Worth|p
Philadelphia|Philadelphia|p
Houston|Houston|p
Atlanta|Atlanta|p
Hagerstown|Hagerstown|p
Washington, D.C.|Washington, D.C.|p
San Francisco|San Francisco|p
Oakland|Oakland|p
San Jose|San Jose|p
Manchester|Manchester|p
Boston|Boston|p
Sarasota|Sarasota|p
Tampa|Tampa|p
St. Petersburg|St. Petersburg|p
Prescott|Prescott|p
Phoenix|Phoenix|p
Seattle|Seattle|p
Tacoma|Tacoma|p
Detroit|Detroit|p
Orlando|Orlando|p
Daytona Beach|Daytona Beach|p
Melbourne|Melbourne|p
Minneapolis|Minneapolis|p
St. Paul|St. Paul|p
Denver|Denver|p
Miami|Miami|p
Fort Lauderdale|Fort Lauderdale|p
Canton|Canton|p
Cleveland|Cleveland|p
Akron|Akron|p
Sacramento|Sacramento|p
Stockton|Stockton|p
Modesto|Modesto|p
Charlotte|Charlotte|p
Fayetteville|Fayetteville|p
Raleigh|Raleigh|p
Durham|Durham|p
Portland|Portland|p
St. Louis|St. Louis|p
Nashville|Nashville|p
Indianapolis|Indianapolis|p
Pittsburgh|Pittsburgh|p
Salt Lake City|Salt Lake City|p
Baltimore|Baltimore|p
San Diego|San Diego|p
San Antonio|San Antonio|p
Kansas City|Kansas City|p
Hartford|Hartford|p
New Haven|New Haven|p
Austin|Austin|p
Columbus|Columbus|p
Greenville|Greenville|p
Spartanburg|Spartanburg|p
Asheville|Asheville|p
Anderson|Anderson|p
Cincinnati|Cincinnati|p
Milwaukee|Milwaukee|p
West Palm Beach|West Palm Beach|p
Fort Pierce|Fort Pierce|p
Las Vegas|Las Vegas|p
Jacksonville|Jacksonville|p
Harrisburg|Harrisburg|p
Lancaster|Lancaster|p
Lebanon|Lebanon|p
York|York|p
Grand Rapids|Grand Rapids|p
Kalamazoo|Kalamazoo|p
Battle Creek|Battle Creek|p
Norfolk|Norfolk|p
Portsmouth|Portsmouth|p
Newport News|Newport News|p
Anniston|Anniston|p
Tuscaloosa|Tuscaloosa|p
Birmingham|Birmingham|p
Greensboro|Greensboro|p
High Point|High Point|p
Winston|Winston|p
Salem|Salem|p
Oklahoma City|Oklahoma City|p
Albuquerque|Albuquerque|p
Santa Fe|Santa Fe|p
Louisville|Louisville|p
New Orleans|New Orleans|p
Memphis|Memphis|p
Providence|Providence|p
New Bedford|New Bedford|p
Fort Myers|Fort Myers|p
Naples|Naples|p
Fresno|Fresno|p
Visalia|Visalia|p
Buffalo|Buffalo|p
Richmond|Richmond|p
Petersburg|Petersburg|p
Fort Walton Beach|Fort Walton Beach|p
Mobile|Mobile|p
Pensacola|Pensacola|p
Little Rock|Little Rock|p
Pine Bluff|Pine Bluff|p
Wilkes Barre|Wilkes Barre|p
Scranton|Scranton|p
Hazleton|Hazleton|p
Knoxville|Knoxville|p
Tulsa|Tulsa|p
Albany|Albany|p
Schenectady|Schenectady|p
Troy|Troy|p
Lexington|Lexington|p
Dayton|Dayton|p
Sierra Vista|Sierra Vista|p
Tucson|Tucson|p
Spokane|Spokane|p
Des Moines|Des Moines|p
Ames|Ames|p
Green Bay|Green Bay|p
Appleton|Appleton|p
Honolulu|Honolulu|p
Roanoke|Roanoke|p
Lynchburg|Lynchburg|p
Wichita|Wichita|p
Hutchinson|Hutchinson|p
Flint|Flint|p
Saginaw|Saginaw|p
Bay City|Bay City|p
Omaha|Omaha|p
Springfield|Springfield|p
Florence|Florence|p
Huntsville|Huntsville|p
Decatur|Decatur|p
Columbia|Columbia|p
Madison|Madison|p
Auburn|Auburn|p
Rochester|Rochester|p
Harlingen|Harlingen|p
Weslaco|Weslaco|p
Brownsville|Brownsville|p
McAllen|McAllen|p
Toledo|Toledo|p
Charleston|Charleston|p
Huntington|Huntington|p
Waco|Waco|p
Temple|Temple|p
Bryan|Bryan|p
Savannah|Savannah|p
Chattanooga|Chattanooga|p
Colorado Springs|Colorado Springs|p
Pueblo|Pueblo|p
Syracuse|Syracuse|p
Las Cruces|Las Cruces|p
El Paso|El Paso|p
Paducah|Paducah|p
Cape Girardeau|Cape Girardeau|p
Shreveport|Shreveport|p
Texarkana|Texarkana|p
Champaign|Champaign|p
Urbana|Urbana|p
Burlington|Burlington|p
Plattsburgh|Plattsburgh|p
Cedar Rapids|Cedar Rapids|p
Waterloo|Waterloo|p
Iowa City|Iowa City|p
Dubuque|Dubuque|p
Baton Rouge|Baton Rouge|p
Fort Smith|Fort Smith|p
Springdale|Springdale|p
Rogers|Rogers|p
Myrtle Beach|Myrtle Beach|p
Boise|Boise|p
Jackson|Jackson|p
South Bend|South Bend|p
Elkhart|Elkhart|p
Tri|Tri|p
Cities|Cities|p
New Bern|New Bern|p
Washington|Washington|p
Reno|Reno|p
Davenport|Davenport|p
Rock Island|Rock Island|p
Moline|Moline|p
Tallahassee|Tallahassee|p
Thomasville|Thomasville|p
Lufkin|Lufkin|p
Nacogdoches|Nacogdoches|p
Tyler|Tyler|p
Longview|Longview|p
Lincoln|Lincoln|p
Hastings|Hastings|p
Kearney|Kearney|p
Augusta|Augusta|p
Aiken|Aiken|p
Evansville|Evansville|p
Fort Wayne|Fort Wayne|p
Mitchell|Mitchell|p
Sioux Falls|Sioux Falls|p
Johnstown|Johnstown|p
Altoona|Altoona|p
State College|State College|p
Fargo|Fargo|p
Valley City|Valley City|p
Yakima|Yakima|p
Pasco|Pasco|p
Richland|Richland|p
Kennewick|Kennewick|p
Holyoke|Holyoke|p
Traverse City|Traverse City|p
Cadillac|Cadillac|p
Lansing|Lansing|p
Youngstown|Youngstown|p
Macon|Macon|p
Eugene|Eugene|p
Montgomery|Montgomery|p
Selma|Selma|p
Peoria|Peoria|p
Bloomington|Bloomington|p
Santa Barbara|Santa Barbara|p
Santa Maria|Santa Maria|p
San Luis Obispo|San Luis Obispo|p
Lafayette|Lafayette|p
Bakersfield|Bakersfield|p
Wilmington|Wilmington|p
Monterey|Monterey|p
Salinas|Salinas|p
La Crosse|La Crosse|p
Eau Claire|Eau Claire|p
Corpus Christi|Corpus Christi|p
Salisbury|Salisbury|p
Amarillo|Amarillo|p
Wausau|Wausau|p
Rhinelander|Rhinelander|p
Tupelo|Tupelo|p
West Point|West Point|p
Starkville|Starkville|p
Jefferson City|Jefferson City|p
Chico|Chico|p
Redding|Redding|p
Rockford|Rockford|p
Duluth|Duluth|p
Superior|Superior|p
Medford|Medford|p
Klamath Falls|Klamath Falls|p
Lubbock|Lubbock|p
Topeka|Topeka|p
Monroe|Monroe|p
El Dorado|El Dorado|p
Beaumont|Beaumont|p
Port Arthur|Port Arthur|p
Odessa|Odessa|p
Midland|Midland|p
Palm Springs|Palm Springs|p
Anchorage|Anchorage|p
Williston|Williston|p
Minot|Minot|p
Bismarck|Bismarck|p
Dickinson|Dickinson|p
Panama City|Panama City|p
Sioux City|Sioux City|p
Wichita Falls|Wichita Falls|p
Lawton|Lawton|p
Joplin|Joplin|p
Pittsburg|Pittsburg|p
Mason City|Mason City|p
Erie|Erie|p
Idaho Falls|Idaho Falls|p
Pocatello|Pocatello|p
Bangor|Bangor|p
Gainesville|Gainesville|p
Biloxi|Biloxi|p
Gulfport|Gulfport|p
Terre Haute|Terre Haute|p
Sherman|Sherman|p
Ada|Ada|p
Missoula|Missoula|p
Binghamton|Binghamton|p
Wheeling|Wheeling|p
Steubenville|Steubenville|p
Yuma|Yuma|p
El Centro|El Centro|p
Billings|Billings|p
Abilene|Abilene|p
Sweetwater|Sweetwater|p
Bluefield|Bluefield|p
Beckley|Beckley|p
Oak Hill|Oak Hill|p
Hattiesburg|Hattiesburg|p
Laurel|Laurel|p
Rapid City|Rapid City|p
Dothan|Dothan|p
Utica|Utica|p
Clarksburg|Clarksburg|p
Weston|Weston|p
Harrisonburg|Harrisonburg|p
Quincy|Quincy|p
Hannibal|Hannibal|p
Keokuk|Keokuk|p
Charlottesville|Charlottesville|p
Lake Charles|Lake Charles|p
Corning|Corning|p
Elmira|Elmira|p
Watertown|Watertown|p
Bowling Green|Bowling Green|p
Marquette|Marquette|p
Jonesboro|Jonesboro|p
Alexandria|Alexandria|p
Laredo|Laredo|p
Butte|Butte|p
Bozeman|Bozeman|p
Bend|Bend|p
Grand Junction|Grand Junction|p
Montrose|Montrose|p
Twin Falls|Twin Falls|p
Lima|Lima|p
Great Falls|Great Falls|p
Meridian|Meridian|p
Cheyenne|Cheyenne|p
Scottsbluff|Scottsbluff|p
Parkersburg|Parkersburg|p
Greenwood|Greenwood|p
Eureka|Eureka|p
San Angelo|San Angelo|p
Casper|Casper|p
Riverton|Riverton|p
Mankato|Mankato|p
Ottumwa|Ottumwa|p
Kirksville|Kirksville|p
St. Joseph|St. Joseph|p
Fairbanks|Fairbanks|p
Zanesville|Zanesville|p
Victoria|Victoria|p
Helena|Helena|p
Presque Isle|Presque Isle|p
Juneau|Juneau|p
Alpena|Alpena|p
North Platte|North Platte|p
Glendive|Glendive|p
Montréal|Montréal|p
Québec|Québec|p
Quebec City|Québec|p
Trois-Rivières|Trois-Rivières|p
Trois Rivieres|Trois-Rivières|p
Saguenay|Saguenay|p
Sherbrooke|Sherbrooke|p
Gatineau|Gatineau|p
Hull|Hull|p
Moncton|Moncton|p
Saint John|Saint John|p
St. John's|St. John's|p
Charlottetown|Charlottetown|p
Halifax|Halifax|p
Sydney|Sydney|p
Fredericton|Fredericton|p
Ottawa|Ottawa|p
Toronto|Toronto|p
Kitchener|Kitchener|p
Cambridge|Cambridge|p
Guelph|Guelph|p
London|London|p
Windsor|Windsor|p
Hamilton|Hamilton|p
Barrie|Barrie|p
Sudbury|Sudbury|p
Thunder Bay|Thunder Bay|p
Winnipeg|Winnipeg|p
Regina|Regina|p
Saskatoon|Saskatoon|p
Calgary|Calgary|p
Edmonton|Edmonton|p
Lethbridge|Lethbridge|p
Red Deer|Red Deer|p
Medicine Hat|Medicine Hat|p
Grande Prairie|Grande Prairie|p
Fort McMurray|Fort McMurray|p
Vancouver|Vancouver|p
Kelowna|Kelowna|p
Prince George|Prince George|p
Kamloops|Kamloops|p
Nanaimo|Nanaimo|p
Abbotsford|Abbotsford|p
Chilliwack|Chilliwack|p
Yellowknife|Yellowknife|p
Whitehorse|Whitehorse|p
Iqaluit|Iqaluit|p
Kingston|Kingston|p
Peterborough|Peterborough|p
Oshawa|Oshawa|p
Belleville|Belleville|p
Brantford|Brantford|p
Niagara|Niagara|p
St. Catharines|St. Catharines|p
Timmins|Timmins|p
North Bay|North Bay|p
Sault Ste. Marie|Sault Ste. Marie|p
Rouyn-Noranda|Rouyn-Noranda|p
Rouyn Noranda|Rouyn-Noranda|p
Rimouski|Rimouski|p
Drummondville|Drummondville|p
Granby|Granby|p
Saint-Hyacinthe|Saint-Hyacinthe|p
Brandon|Brandon|p
Prince Albert|Prince Albert|p
Moose Jaw|Moose Jaw|p
Swift Current|Swift Current|p
Brockville|Brockville|p
Cornwall|Cornwall|p
Pembroke|Pembroke|p
Mississauga|Mississauga|p
Brampton|Brampton|p
Markham|Markham|p
Oakville|Oakville|p
Laval|Laval|p
Longueuil|Longueuil|p
Lloydminster|Lloydminster|p
Cranbrook|Cranbrook|p
Dawson Creek|Dawson Creek|p
Terrace|Terrace|p
Kenora|Kenora|p
Wingham|Wingham|p
Orillia|Orillia|p
Stratford|Stratford|p
Chatham|Chatham|p
Sarnia|Sarnia|p
Owen Sound|Owen Sound|p
Cape Breton|Cape Breton|p
Truro|Truro|p
Yarmouth|Yarmouth|p
Corner Brook|Corner Brook|p
Gander|Gander|p
Grand Falls|Grand Falls|p
Bathurst|Bathurst|p
Edmundston|Edmundston|p
Campbellton|Campbellton|p
Val-d'Or|Val-d'Or|p
Val d'Or|Val-d'Or|p
Chicoutimi|Chicoutimi|p
Jonquière|Jonquière|p
Baie-Comeau|Baie-Comeau|p
Baie Comeau|Baie-Comeau|p
Sept-Îles|Sept-Îles|p
Sept Iles|Sept-Îles|p
Gaspé|Gaspé|p
Rivière-du-Loup|Rivière-du-Loup|p
Riviere du Loup|Rivière-du-Loup|p
Victoriaville|Victoriaville|p
Joliette|Joliette|p
Saint-Jérôme|Saint-Jérôme|p
Saint Jerome|Saint-Jérôme|p
Lévis|Lévis|p
Atlantic|Atlantic|p
Atlantique|Atlantic|p
Maritimes|Maritimes|p
Maritime|Maritimes|p
Acadie|Acadie|p
Acadia|Acadie|p
Estrie|Estrie|p
Mauricie|Mauricie|p
Manitoba|Manitoba|s
Ontario|Ontario|s
Pacific|Pacific|f
Prairies|Prairies|p
Prairie|Prairies|p
East|East|f
West|West|f
Alberta|Alberta|s
Saskatchewan|Saskatchewan|s
British Columbia|British Columbia|s
Colombie-Britannique|British Columbia|s
BC|British Columbia|s
Yukon|Yukon|s
Nunavut|Nunavut|s
Northwest Territories|Northwest Territories|s
Newfoundland|Newfoundland|s
Labrador|Labrador|s
Nova Scotia|Nova Scotia|s
New Brunswick|New Brunswick|s
Prince Edward Island|Prince Edward Island|s
PEI|Prince Edward Island|s
Northern Ontario|Northern Ontario|p
Capital Region|Capital Region|p
Est-Québec|Est-Québec|p
Rocky Mountain|Rocky Mountain|p
Northwest|Northwest|p
Midwest|Midwest|p
Southeast|Southeast|p
Southwest|Southwest|p
Northeast|Northeast|p
Mid-Atlantic|Mid-Atlantic|p
South Florida|South Florida|p
Central NY|Central NY|p
So Cal|Southern California|p
SoCal|Southern California|p
Mountain|Mountain|f
Coastal|Coastal|p
Worcester|Worcester|p
Pittsfield|Pittsfield|p
Winston-Salem|Winston-Salem|p
Wilkes-Barre|Wilkes-Barre|p
Orange County|Orange County|p
Brooklyn|Brooklyn|p
Queens|Queens|p
Bronx|Bronx|p
Manhattan|Manhattan|p
Staten Island|Staten Island|p
Long Island|Long Island|p
Saint Paul|Saint Paul|p
College Station|College Station|p
Ocala|Ocala|p
Grand Forks|Grand Forks|p
Atlantic City|Atlantic City|p
Tri-Cities|Tri-Cities|p
Bristol|Bristol|p
Johnson City|Johnson City|p
Kingsport|Kingsport|p
Valdosta|Valdosta|p
Garden City|Garden City|p
Saint Joseph|Saint Joseph|p
Ardmore|Ardmore|p
Denison|Denison|p
Farmington|Farmington|p
Flagstaff|Flagstaff|p
Elko|Elko|p
Provo|Provo|p
Ogden|Ogden|p
Hilo|Hilo|p
Wailuku|Wailuku|p
Guam|Guam|p
Puerto Rico|Puerto Rico|p
San Juan|San Juan|p
Mayaguez|Mayaguez|p
Ponce|Ponce|p
Tijuana|Tijuana|p
Chula Vista|Chula Vista|p
Escondido|Escondido|p
Riverside|Riverside|p
San Bernardino|San Bernardino|p
Long Beach|Long Beach|p
Pasadena|Pasadena|p
Glendale|Glendale|p
Burbank|Burbank|p
Galveston|Galveston|p
Arlington|Arlington|p
Plano|Plano|p
Irving|Irving|p
Garland|Garland|p
Denton|Denton|p
Mesa|Mesa|p
Tempe|Tempe|p
Scottsdale|Scottsdale|p
Chandler|Chandler|p
Henderson|Henderson|p
Paradise|Paradise|p
Gary|Gary|p
Hammond|Hammond|p
Quad Cities|Quad Cities|p
Chillicothe|Chillicothe|p
Ashland|Ashland|p
Marion|Marion|p
Owensboro|Owensboro|p
Hopkinsville|Hopkinsville|p
Murfreesboro|Murfreesboro|p
Cookeville|Cookeville|p
Oxford|Oxford|p
Clarksdale|Clarksdale|p
Natchez|Natchez|p
Vicksburg|Vicksburg|p
Zachary|Zachary|p
Brunswick|Brunswick|p
Waycross|Waycross|p
Lake Placid|Lake Placid|p
Sebring|Sebring|p
Destin|Destin|p
Marianna|Marianna|p
Cocoa|Cocoa|p
Titusville|Titusville|p
Vero Beach|Vero Beach|p
Stuart|Stuart|p
Boca Raton|Boca Raton|p
Boynton Beach|Boynton Beach|p
Delray Beach|Delray Beach|p
Hialeah|Hialeah|p
Coral Gables|Coral Gables|p
Key West|Key West|p
Marathon|Marathon|p
Homestead|Homestead|p
Baytown|Baytown|p
Bay Area|Bay Area|m
Silicon Valley|Silicon Valley|p
New England|New England|p
Tri-State|Tri-State|p
Tri State|Tri State|p
Hudson Valley|Hudson Valley|p
Southern Tier|Southern Tier|p
Finger Lakes|Finger Lakes|p
Central Texas|Central Texas|p
Rio Grande Valley|Rio Grande Valley|p
Permian Basin|Permian Basin|p
Big Country|Big Country|p
Panhandle|Panhandle|p
Delta|Delta|p
Ozarks|Ozarks|p
Piedmont|Piedmont|p
Lowcountry|Lowcountry|p
Treasure Coast|Treasure Coast|p
Space Coast|Space Coast|p
Gulf Coast|Gulf Coast|p
Emerald Coast|Emerald Coast|p
Inland Empire|Inland Empire|p
Central Valley|Central Valley|p
Gold Country|Gold Country|p
Four Corners|Four Corners|p
Black Hills|Black Hills|p
Upper Peninsula|Upper Peninsula|p
West Michigan|West Michigan|p
Southwest Florida|Southwest Florida|p
Chicagoland|Chicagoland|p
Twin Cities|Twin Cities|p
Big Sky|Big Sky|p
Alabama|Alabama|s
Alaska|Alaska|s
Arizona|Arizona|s
Arkansas|Arkansas|s
California|California|s
Colorado|Colorado|s
Connecticut|Connecticut|s
Delaware|Delaware|s
Florida|Florida|s
Georgia|Georgia|s
Hawaii|Hawaii|s
Idaho|Idaho|s
Illinois|Illinois|s
Indiana|Indiana|s
Iowa|Iowa|s
Kansas|Kansas|s
Kentucky|Kentucky|s
Louisiana|Louisiana|s
Maine|Maine|s
Maryland|Maryland|s
Massachusetts|Massachusetts|s
Michigan|Michigan|s
Minnesota|Minnesota|s
Mississippi|Mississippi|s
Missouri|Missouri|s
Montana|Montana|s
Nebraska|Nebraska|s
Nevada|Nevada|s
New Hampshire|New Hampshire|s
New Jersey|New Jersey|s
New Mexico|New Mexico|s
North Carolina|North Carolina|s
North Dakota|North Dakota|s
Ohio|Ohio|s
Oklahoma|Oklahoma|s
Oregon|Oregon|s
Pennsylvania|Pennsylvania|s
Rhode Island|Rhode Island|s
South Carolina|South Carolina|s
South Dakota|South Dakota|s
Tennessee|Tennessee|s
Texas|Texas|s
Utah|Utah|s
Vermont|Vermont|s
Virginia|Virginia|s
West Virginia|West Virginia|s
Wisconsin|Wisconsin|s
Wyoming|Wyoming|s
District of Columbia|District of Columbia|s
Carolinas|Carolinas|s
Mount Cheaha|Mount Cheaha|p
Bessemer|Bessemer|p
Homewood|Homewood|p
Hoover|Hoover|p
Gadsden|Gadsden|p
Dozier|Dozier|p
Ozark|Ozark|p
Gulf Shores|Gulf Shores|p
Tuskegee|Tuskegee|p
Opelika|Opelika|p
Demopolis|Demopolis|p
North Pole|North Pole|p
Holbrook|Holbrook|p
Tolleson|Tolleson|p
Green Valley|Green Valley|p
Eureka Springs|Eureka Springs|p
Mountain View|Mountain View|p
Arkadelphia|Arkadelphia|p
Hot Springs|Hot Springs|p
Camden|Camden|p
Harrison|Harrison|p
Arcata|Arcata|p
Hanford|Hanford|p
Tulare|Tulare|p
Merced|Merced|p
Clovis|Clovis|p
Sanger|Sanger|p
Porterville|Porterville|p
Bishop|Bishop|p
Santa Ana|Santa Ana|p
Rancho Palos Verdes|Rancho Palos Verdes|p
Huntington Beach|Huntington Beach|p
Corona|Corona|p
Avalon|Avalon|p
Anaheim|Anaheim|p
Ventura|Ventura|p
Garden Grove|Garden Grove|p
Inglewood|Inglewood|p
Watsonville|Watsonville|p
Colusa|Colusa|p
Ceres|Ceres|p
Fort Bragg|Fort Bragg|p
Cotati|Cotati|p
Concord|Concord|p
Fremont|Fremont|p
San Mateo|San Mateo|p
Vallejo|Vallejo|p
Palo Alto|Palo Alto|p
Calipatria|Calipatria|p
Sterling|Sterling|p
Broomfield|Broomfield|p
Boulder|Boulder|p
Fort Collins|Fort Collins|p
Longmont|Longmont|p
Greeley|Greeley|p
Castle Rock|Castle Rock|p
Waterbury|Waterbury|p
New London|New London|p
New Britain|New Britain|p
Norwich|Norwich|p
Bridgeport|Bridgeport|p
Dover|Dover|p
Seaford|Seaford|p
Cape Coral|Cape Coral|p
Tice|Tice|p
High Springs|High Springs|p
Orange Park|Orange Park|p
Clermont|Clermont|p
Leesburg|Leesburg|p
Panama City Beach|Panama City Beach|p
Live Oak|Live Oak|p
Clearwater|Clearwater|p
Lakeland|Lakeland|p
Venice|Venice|p
Bradenton|Bradenton|p
Tequesta|Tequesta|p
Palm Beach|Palm Beach|p
Lake Worth|Lake Worth|p
Pelham|Pelham|p
Dawson|Dawson|p
Cordele|Cordele|p
Rome|Rome|p
Toccoa|Toccoa|p
Wrens|Wrens|p
Cochran|Cochran|p
Perry|Perry|p
Beaufort|Beaufort|p
Baxley|Baxley|p
Bainbridge|Bainbridge|p
Chatsworth|Chatsworth|p
Dalton|Dalton|p
Kailua|Kailua|p
Waimānalo|Waimānalo|p
Kāneʻohe|Kāneʻohe|p
Kailua-Kona|Kailua-Kona|p
Nampa|Nampa|p
Caldwell|Caldwell|p
Lewiston|Lewiston|p
Moscow|Moscow|p
Coeur d'Alene|Coeur d'Alene|p
Naperville|Naperville|p
Aurora|Aurora|p
Joliet|Joliet|p
Oswego|Oswego|p
Macomb|Macomb|p
Freeport|Freeport|p
Galesburg|Galesburg|p
Olney|Olney|p
Carbondale|Carbondale|p
Mount Vernon|Mount Vernon|p
East St. Louis|East St. Louis|p
Angola|Angola|p
Kokomo|Kokomo|p
Muncie|Muncie|p
Vincennes|Vincennes|p
Fort Dodge|Fort Dodge|p
Newton|Newton|p
Council Bluffs|Council Bluffs|p
Red Oak|Red Oak|p
Lakin|Lakin|p
Ensign|Ensign|p
Dodge City|Dodge City|p
Colby|Colby|p
Great Bend|Great Bend|p
Hoisington|Hoisington|p
Salina|Salina|p
Derby|Derby|p
Lawrence|Lawrence|p
Morehead|Morehead|p
Owenton|Owenton|p
Danville|Danville|p
Beattyville|Beattyville|p
Elizabethtown|Elizabethtown|p
Murray|Murray|p
Pikeville|Pikeville|p
Somerset|Somerset|p
Hazard|Hazard|p
Harlan|Harlan|p
Madisonville|Madisonville|p
Newport|Newport|p
Covington|Covington|p
New Iberia|New Iberia|p
Minden|Minden|p
West Monroe|West Monroe|p
Slidell|Slidell|p
Orono|Orono|p
Poland Spring|Poland Spring|p
Waterville|Waterville|p
Biddeford|Biddeford|p
Calais|Calais|p
Annapolis|Annapolis|p
Frederick|Frederick|p
Silver Spring|Silver Spring|p
Norwell|Norwell|p
Lowell|Lowell|p
Woburn|Woburn|p
Foxborough|Foxborough|p
Marlborough|Marlborough|p
Ann Arbor|Ann Arbor|p
Mount Clemens|Mount Clemens|p
Bad Axe|Bad Axe|p
Muskegon|Muskegon|p
Onondaga|Onondaga|p
East Lansing|East Lansing|p
Escanaba|Escanaba|p
Calumet|Calumet|p
Ishpeming|Ishpeming|p
Cheboygan|Cheboygan|p
Mount Pleasant|Mount Pleasant|p
Manistee|Manistee|p
Vanderbilt|Vanderbilt|p
Brainerd|Brainerd|p
Chisholm|Chisholm|p
St. Cloud|St. Cloud|p
Thief River Falls|Thief River Falls|p
Crookston|Crookston|p
Worthington|Worthington|p
Bude|Bude|p
Magee|Magee|p
Mississippi State|Mississippi State|p
Booneville|Booneville|p
Senatobia|Senatobia|p
Holly Springs|Holly Springs|p
Sedalia|Sedalia|p
Osage Beach|Osage Beach|p
Poplar Bluff|Poplar Bluff|p
Hardin|Hardin|p
Bassett|Bassett|p
Hayes Center|Hayes Center|p
Merriman|Merriman|p
Sidney|Sidney|p
Alliance|Alliance|p
McCook|McCook|p
Laughlin|Laughlin|p
Derry|Derry|p
Merrimack|Merrimack|p
Keene|Keene|p
Littleton|Littleton|p
Secaucus|Secaucus|p
Newark|Newark|p
Middletown Township|Middletown Township|p
Paterson|Paterson|p
Linden|Linden|p
Montclair|Montclair|p
Wildwood|Wildwood|p
Princeton|Princeton|p
Millville|Millville|p
Trenton|Trenton|p
Vineland|Vineland|p
Portales|Portales|p
Hobbs|Hobbs|p
Jamestown|Jamestown|p
Batavia|Batavia|p
Springville|Springville|p
New Rochelle|New Rochelle|p
Riverhead|Riverhead|p
Smithtown|Smithtown|p
Ithaca|Ithaca|p
Carthage|Carthage|p
Saranac Lake|Saranac Lake|p
Hickory|Hickory|p
Linville|Linville|p
Belmont|Belmont|p
Rock Hill|Rock Hill|p
Kannapolis|Kannapolis|p
Chapel Hill|Chapel Hill|p
Goldsboro|Goldsboro|p
Wilson|Wilson|p
Roanoke Rapids|Roanoke Rapids|p
Rocky Mount|Rocky Mount|p
Lumberton|Lumberton|p
Edenton|Edenton|p
Manteo|Manteo|p
Ellendale|Ellendale|p
Devils Lake|Devils Lake|p
Pembina|Pembina|p
Shaker Heights|Shaker Heights|p
Lorain|Lorain|p
Sandusky|Sandusky|p
Athens|Athens|p
Shawnee|Shawnee|p
Woodward|Woodward|p
Norman|Norman|p
Bartlesville|Bartlesville|p
Muskogee|Muskogee|p
Claremore|Claremore|p
Okmulgee|Okmulgee|p
Eufaula|Eufaula|p
Corvallis|Corvallis|p
Grants Pass|Grants Pass|p
Pendleton|Pendleton|p
Bethlehem|Bethlehem|p
Red Lion|Red Lion|p
Clearfield|Clearfield|p
Willow Grove|Willow Grove|p
Jeannette|Jeannette|p
Greensburg|Greensburg|p
Williamsport|Williamsport|p
Aguadilla|Aguadilla|p
San Sebastián|San Sebastián|p
Yauco|Yauco|p
Aguada|Aguada|p
Arecibo|Arecibo|p
Carolina|Carolina|p
Fajardo|Fajardo|p
Caguas|Caguas|p
Toa Baja|Toa Baja|p
Bayamón|Bayamón|p
Guayama|Guayama|p
Naranjito|Naranjito|p
Humacao|Humacao|p
Sumter|Sumter|p
Conway|Conway|p
Allendale|Allendale|p
Hardeeville|Hardeeville|p
Lowry|Lowry|p
Aberdeen|Aberdeen|p
Reliance|Reliance|p
Martin|Martin|p
Lead|Lead|p
Eagle Butte|Eagle Butte|p
Vermillion|Vermillion|p
Brookings|Brookings|p
Sneedville|Sneedville|p
Greeneville|Greeneville|p
Crossville|Crossville|p
Tazewell|Tazewell|p
Jellico|Jellico|p
Franklin|Franklin|p
Hendersonville|Hendersonville|p
Borger|Borger|p
Llano|Llano|p
Killeen|Killeen|p
Lake Dallas|Lake Dallas|p
Rio Grande City|Rio Grande City|p
Rosenberg|Rosenberg|p
Conroe|Conroe|p
Katy|Katy|p
Alvin|Alvin|p
Snyder|Snyder|p
Big Spring|Big Spring|p
Fredericksburg|Fredericksburg|p
Blanco|Blanco|p
Uvalde|Uvalde|p
Kerrville|Kerrville|p
Belton|Belton|p
Montpelier|Montpelier|p
St. Johnsbury|St. Johnsbury|p
Rutland, Vermont|Rutland, Vermont|p
Culpeper|Culpeper|p
Staunton|Staunton|p
Hampton|Hampton|p
Virginia Beach|Virginia Beach|p
Spotsylvania Courthouse|Spotsylvania Courthouse|p
Grundy|Grundy|p
Front Royal|Front Royal|p
Manassas|Manassas|p
Everett|Everett|p
Bellevue|Bellevue|p
Pullman|Pullman|p
Bellingham|Bellingham|p
Grandview|Grandview|p
Lewisburg|Lewisburg|p
Morgantown|Morgantown|p
Martinsburg|Martinsburg|p
Menomonie|Menomonie|p
Chippewa Falls|Chippewa Falls|p
Suring|Suring|p
Shawano|Shawano|p
Janesville|Janesville|p
Racine|Racine|p
Mayville|Mayville|p
Kenosha|Kenosha|p
Fond du Lac|Fond Du Lac|p
Crandon|Crandon|p
Eagle River|Eagle River|p
Park Falls|Park Falls|p
Antigo|Antigo|p
Laramie|Laramie|p
Rock Springs|Rock Springs|p
Hampton Roads|Hampton Roads|p
Tampa Bay|Tampa Bay|p
Ft Lauderdale|Fort Lauderdale|p
Molin|Moline|p
Mt Vernon|Mount Vernon|p
Mt Verno|Mount Vernon|p
Palm Desert|Palm Desert|p
Winter Park|Winter Park|p
Bala Cynwyd|Bala Cynwyd|p
Lompoc|Lompoc|p
Eddy|Eddy|p
Marana|Marana|p
The Colony|The Colony|p
North Las Vegas|North Las Vegas|p
Parker|Parker|p
Mission|Mission|p
Pearland|Pearland|p
Norwalk|Norwalk|p
Pinellas Park|Pinellas Park|p
Incline|Incline|p
Greenwood-Greenville|Greenwood-Greenville|p
Marietta|Marietta|p
Trinidad|Trinidad|p
"""
}
