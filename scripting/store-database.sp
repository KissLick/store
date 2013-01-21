#include <store/store-logging>
#include <store/store-database>
#include <store/store-inventory>

#define MAX_CATEGORIES	32
#define MAX_ITEMS 		1024
#define MAX_LOADOUTS	32

enum Category
{
	CategoryId,
	String:CategoryDisplayName[64],
	String:CategoryDescription[128],
	String:CategoryRequirePlugin[32]
}

enum Item
{
	ItemId,
	String:ItemName[32],
	String:ItemDisplayName[64],
	String:ItemDescription[128],
	String:ItemType[32],
	String:ItemLoadoutSlot[32],
	ItemPrice,
	ItemCategoryId
}

enum Loadout
{
	LoadoutId,
	String:LoadoutDisplayName[64],
	String:LoadoutGame[32],
	String:LoadoutClass[32],
	LoadoutTeam
}

new Handle:g_dbInitializedForward;

new Handle:g_reloadItemsForward;
new Handle:g_reloadItemsPostForward;

new Handle:g_hSQL;
new g_reconnectCounter = 0;

new g_categories[MAX_CATEGORIES][Category];
new g_categoryCount = -1;

new g_items[MAX_ITEMS][Item];
new g_itemCount = -1;

new g_loadouts[MAX_LOADOUTS][Loadout];
new g_loadoutCount = -1;

/**
 * Called before plugin is loaded.
 * 
 * @param myself    The plugin handle.
 * @param late      True if the plugin was loaded after map change, false on map start.
 * @param error     Error message if load failed.
 * @param err_max   Max length of the error message.
 *
 * @return          APLRes_Success for load success, APLRes_Failure or APLRes_SilentFailure otherwise.
 */
public APLRes:AskPluginLoad2(Handle:myself, bool:late, String:error[], err_max)
{
	CreateNative("Store_Register", Native_Register);
	CreateNative("Store_RegisterClient", Native_RegisterClient);

	CreateNative("Store_GetCategories", Native_GetCategories);
	CreateNative("Store_GetCategoryDisplayName", Native_GetCategoryDisplayName);
	CreateNative("Store_GetCategoryDescription", Native_GetCategoryDescription);
	CreateNative("Store_GetCategoryPluginRequired", Native_GetCategoryPluginRequired);
	
	CreateNative("Store_GetItems", Native_GetItems);
	CreateNative("Store_GetItemName", Native_GetItemName);	
	CreateNative("Store_GetItemDisplayName", Native_GetItemDisplayName);
	CreateNative("Store_GetItemDescription", Native_GetItemDescription);
	CreateNative("Store_GetItemType", Native_GetItemType);
	CreateNative("Store_GetItemLoadoutSlot", Native_GetItemLoadoutSlot);
	CreateNative("Store_GetItemPrice", Native_GetItemPrice);
	CreateNative("Store_GetItemCategory", Native_GetItemCategory);	

	CreateNative("Store_GetLoadouts", Native_GetLoadouts);
	CreateNative("Store_GetLoadoutDisplayName", Native_GetLoadoutDisplayName);
	CreateNative("Store_GetLoadoutGame", Native_GetLoadoutGame);
	CreateNative("Store_GetLoadoutClass", Native_GetLoadoutClass);
	CreateNative("Store_GetLoadoutTeam", Native_GetLoadoutTeam);
	
	CreateNative("Store_GetUserItems", Native_GetUserItems);
	CreateNative("Store_GetCredits", Native_GetCredits);
	
	CreateNative("Store_GiveCredits", Native_GiveCredits);
	CreateNative("Store_GiveCreditsToUsers", Native_GiveCreditsToUsers);	

	CreateNative("Store_BuyItem", Native_BuyItem);
	CreateNative("Store_UseItem", Native_UseItem);
	
	CreateNative("Store_EquipItem", Native_EquipItem);
	CreateNative("Store_UnequipItem", Native_UnequipItem);   
	CreateNative("Store_GetEquippedItemsByType", Native_GetEquippedItemsByType);
	
	RegPluginLibrary("store-database");	
	return APLRes_Success;
}

/**
 * Plugin is loading.
 */
public OnPluginStart()
{
	g_dbInitializedForward = CreateGlobalForward("Store_OnDatabaseInitialized", ET_Event);
	
	g_reloadItemsForward = CreateGlobalForward("Store_OnReloadItems", ET_Event);
	g_reloadItemsPostForward = CreateGlobalForward("Store_OnReloadItemsPost", ET_Event);
		
	// LoadConfig();
	ConnectSQL();
}

/**
* Registers a player in the database:
* 
* - If the player is already in the database, his name will be updated according
*   to the 'name' parameter provided.
*
* - If the player is not in the database (for example, a new player who just joined
*   the server for the first time), he will be added using the account ID and name 
*   provided.
*
* As with all other store-database methods, this method is completely asynchronous.
*
* @param accountId		The account ID of the player, use Store_GetClientAccountID to convert a client index to account ID.
* @param name          The name of the player.
*
* @noreturn
*/
Register(accountId, const String:name[] = "")
{
	decl String:safeName[2 * 32 + 1];
	SQL_EscapeString(g_hSQL, name, safeName, sizeof(safeName));
	
	decl String:query[255];
	Format(query, sizeof(query), "INSERT INTO store_users (auth, name, credits) VALUES (%d, '%s', 0) ON DUPLICATE KEY UPDATE name = '%s';", accountId, safeName, safeName);

	Store_LogError(query);
	SQL_TQuery(g_hSQL, T_EmptyCallback, query);
}

/**
* Registers a player in the database, provided his client index only. 
*
* This method converts the client index provided to an account id, retrieves 
* the player's name, and calls Store_Register using that information.
*
* The logic of registering a player is explained in the Store_Register documentation.
*
* The store-core module calls this method every time a player joins the server.
*
* As with all other store-database methods, this method is completely asynchronous.
*
* @param client		    Client index.
*
* @noreturn
*/
RegisterClient(client)
{
	decl String:name[64];
	GetClientName(client, name, sizeof(name));
	
	Register(Store_GetClientAccountID(client), name);
}

public T_EmptyCallback(Handle:owner, Handle:hndl, const String:error[], any:data)
{
	if (hndl == INVALID_HANDLE)
	{
		Store_LogError("SQL Error on Register: %s", error);
		return;
	}
}

/**
* Retrieves all item categories from the database. 
*
* The store-database module builds a cache of the categories retrieved the first time 
* this method is called, for faster access the next time it's called.
*
* You can set the loadFromCache parameter of this method to false to retrieve categories
* from the database and not from the cache.
*
* The store-core module calls this method when it is loaded to build a cache of 
* categories.
*
* It also provides the store_reloaditems command to reload items and categories 
* from the database. 
*
* To use this method, you can provide a callback for when the categories are loaded.
* The callback will provide an array of the categories' IDs. You can then loop the array,
* and find info about each category using the Store_GetCategory* methods.
*
* As with all other store-database methods, this method is completely asynchronous.
*
* @param callback		    A callback which will be called when the categories are loaded.
* @param plugin				The plugin owner of the callback.
* @param loadFromCache     	Whether to load categories from cache. If false, the method will 
*                          	query the database and rebuild its cache.
* @param data              	Extra data value to pass to the callback.
*
* @noreturn
*/
GetCategories(Store_GetItemsCallback:callback = Store_GetItemsCallback:INVALID_HANDLE, Handle:plugin = INVALID_HANDLE, bool:loadFromCache = true, any:data = 0)
{
	if (loadFromCache && g_categoryCount != -1)
	{
		if (callback != Store_GetItemsCallback:INVALID_HANDLE)
		{
			new ids[g_categoryCount];
			new count = 0;
			
			for (new category = 0; category < g_categoryCount; category++)
			{
				ids[count] = g_categories[category][CategoryId];
				count++;
			}
			
			Call_StartFunction(plugin, Function:callback);
			Call_PushArray(ids, count);
			Call_PushCell(count);
			Call_PushCell(data);
			Call_Finish();
		}
	}
	else
	{
		new Handle:pack = CreateDataPack();
		WritePackCell(pack, _:callback);
		WritePackCell(pack, _:plugin);
		WritePackCell(pack, _:data);
	
		SQL_TQuery(g_hSQL, T_GetCategoriesCallback, "SELECT id, display_name, description, require_plugin FROM store_categories", pack);
	}
}

public T_GetCategoriesCallback(Handle:owner, Handle:hndl, const String:error[], any:pack)
{
	if (hndl == INVALID_HANDLE)
	{
		Store_LogError("SQL Error on GetCategories: %s", error);
		return;
	}
	
	ResetPack(pack);
	
	new Store_GetItemsCallback:callback = Store_GetItemsCallback:ReadPackCell(pack);
	new Handle:plugin = Handle:ReadPackCell(pack);
	new arg = ReadPackCell(pack);
	
	CloseHandle(pack);
	
	g_categoryCount = 0;
	
	while (SQL_FetchRow(hndl))
	{
		g_categories[g_categoryCount][CategoryId] = SQL_FetchInt(hndl, 0);
		SQL_FetchString(hndl, 1, g_categories[g_categoryCount][CategoryDisplayName], 64);
		SQL_FetchString(hndl, 2, g_categories[g_categoryCount][CategoryDescription], 128);
		SQL_FetchString(hndl, 3, g_categories[g_categoryCount][CategoryRequirePlugin], 32);
		
		g_categoryCount++;
	}
	
	GetCategories(callback, plugin, true, arg);
}

GetCategoryIndex(id)
{
	for (new index = 0; index < g_categoryCount; index++)
	{
		if (g_categories[index][CategoryId] == id)
			return index;
	}
	
	return -1;
}

/**
* Retrieves items from the database. 
*
* The store-database module builds a cache of the items retrieved the first time 
* this method is called, for faster access the next time it's called.
*
* You can set the loadFromCache parameter of this method to false to retrieve categories
* from the database and not from the cache.
*
* The store-core module calls this method when it is loaded to build a cache of 
* categories.
*
* It also provides the store_reloaditems command to reload items and categories 
* from the database. 
*
* To use this method, you can provide a callback for when the items are loaded.
* The callback will provide an array of the items' IDs. You can then loop the array,
* and find info about each item using the Store_GetItem* methods.
*
* As with all other store-database methods, this method is completely asynchronous.
*
* @param callback		    A callback which will be called when the items are loaded.
* @param plugin				The plugin owner of the callback.
* @param categoryId        	Filter the items returned by a category ID.
* @param loadFromCache     	Whether to load items from cache. If false, the method will 
*                          	query the database and rebuild its cache.
* @param data              	Extra data value to pass to the callback.
*
* @noreturn
*/
GetItems(Store_GetItemsCallback:callback = Store_GetItemsCallback:INVALID_HANDLE, Handle:plugin = INVALID_HANDLE, categoryId = -1, bool:loadFromCache = true, any:data = 0)
{	
	if (loadFromCache && g_itemCount != -1)
	{
		if (callback != Store_GetItemsCallback:INVALID_HANDLE)
		{
			new ids[g_itemCount];
			new count = 0;
			
			for (new item = 0; item < g_itemCount; item++)
			{
				if (categoryId == -1 || categoryId == g_items[item][ItemCategoryId])
				{
					ids[count] = g_items[item][ItemId];
					count++;
				}
			}
			
			Call_StartFunction(plugin, Function:callback);
			Call_PushArray(ids, count);
			Call_PushCell(count);
			Call_PushCell(data);
			Call_Finish();
		}
	}
	else
	{
		new Handle:pack = CreateDataPack();
		WritePackCell(pack, _:callback);
		WritePackCell(pack, _:plugin);
		WritePackCell(pack, categoryId);
		WritePackCell(pack, _:data);
	
		SQL_TQuery(g_hSQL, T_GetItemsCallback, "SELECT id, name, display_name, description, type, loadout_slot, price, category_id, attrs FROM store_items", pack);
	}
}

public T_GetItemsCallback(Handle:owner, Handle:hndl, const String:error[], any:pack)
{
	if (hndl == INVALID_HANDLE)
	{
		Store_LogError("SQL Error on GetItems: %s", error);
		return;
	}
	
	Call_StartForward(g_reloadItemsForward);
	Call_Finish();
	
	ResetPack(pack);
	
	new Store_GetItemsCallback:callback = Store_GetItemsCallback:ReadPackCell(pack);
	new Handle:plugin = Handle:ReadPackCell(pack);
	new categoryId = ReadPackCell(pack);
	new arg = ReadPackCell(pack);
	
	CloseHandle(pack);
	
	g_itemCount = 0;
	
	while (SQL_FetchRow(hndl))
	{
		g_items[g_itemCount][ItemId] = SQL_FetchInt(hndl, 0);
		SQL_FetchString(hndl, 1, g_items[g_itemCount][ItemName], 32);
		SQL_FetchString(hndl, 2, g_items[g_itemCount][ItemDisplayName], 64);
		SQL_FetchString(hndl, 3, g_items[g_itemCount][ItemDescription], 128);
		SQL_FetchString(hndl, 4, g_items[g_itemCount][ItemType], 32);
		SQL_FetchString(hndl, 5, g_items[g_itemCount][ItemLoadoutSlot], 32);
		g_items[g_itemCount][ItemPrice] = SQL_FetchInt(hndl, 6);		
		g_items[g_itemCount][ItemCategoryId] = SQL_FetchInt(hndl, 7);
		
		if (!SQL_IsFieldNull(hndl, 8))
		{
			decl String:attrs[1024];
			SQL_FetchString(hndl, 8, attrs, sizeof(attrs));
			
			Store_CallItemAttrsCallback(g_items[g_itemCount][ItemType], g_items[g_itemCount][ItemName], attrs);
		}
		
		g_itemCount++;
	}
	
	Call_StartForward(g_reloadItemsPostForward);
	Call_Finish();
	
	GetItems(callback, plugin, categoryId, true, arg);
}

GetItemIndex(id)
{
	for (new index = 0; index < g_itemCount; index++)
	{
		if (g_items[index][ItemId] == id)
			return index;
	}
	
	return -1;
}

/**
* Retrieves loadouts from the database. 
*
* The store-database module builds a cache of the loadouts retrieved the first time 
* this method is called, for faster access the next time it's called.
*
* You can set the loadFromCache parameter of this method to false to retrieve loadouts
* from the database and not from the cache.
*
* You can use the filter parameter to filter loadouts returned by the following properties:
*  - game (string)
*  - team (cell)
*  - class (string)
*
* To use it, set it to a trie with some or all of the above properties.
* IMPORTANT: You are *not* resposible for closing the filter trie's handle, 
*            the store-database module is.
* 
* The store-loadout module calls this method when it is loaded to build a cache of 
* loadouts.
*
* To use this method, you can provide a callback for when the items are loaded.
* The callback will provide an array of the loadouts' IDs. You can then loop the array,
* and find info about each item using the Store_GetLoadout* methods.
*
* As with all other store-database methods, this method is completely asynchronous.
*
* @param filter            	A trie which will be used to filter the loadouts returned.
* @param callback		   	A callback which will be called when the items are loaded.
* @param plugin				The plugin owner of the callback.
* @param loadFromCache     	Whether to load items from cache. If false, the method will 
*                          	query the database and rebuild its cache.
* @param data              	Extra data value to pass to the callback.
*
* @noreturn
*/
GetLoadouts(Handle:filter, Store_GetItemsCallback:callback = Store_GetItemsCallback:INVALID_HANDLE, Handle:plugin = INVALID_HANDLE, bool:loadFromCache = true, any:data = 0)
{
	if (loadFromCache && g_loadoutCount != -1 && callback != Store_GetItemsCallback:INVALID_HANDLE)
	{
		new ids[g_loadoutCount];
		new count = 0;
		
		decl String:game[32];
		new bool:gameFilter = filter == INVALID_HANDLE ? false : GetTrieString(filter, "game", game, sizeof(game));
		
		decl String:class[32];
		new bool:classFilter = filter == INVALID_HANDLE ? false : GetTrieString(filter, "class", class, sizeof(class));
		
		new team = -1;
		new bool:teamFilter = filter == INVALID_HANDLE ? false : GetTrieValue(filter, "team", team);
		
		CloseHandle(filter);
		
		for (new loadout = 0; loadout < g_loadoutCount; loadout++)
		{	
			if (
				(!gameFilter || StrEqual(game, "") || StrEqual(g_loadouts[loadout][LoadoutGame], "") || StrEqual(game, g_loadouts[loadout][LoadoutGame])) &&
			 	(!classFilter || StrEqual(class, "") || StrEqual(g_loadouts[loadout][LoadoutClass], "") || StrEqual(class, g_loadouts[loadout][LoadoutClass])) &&
				(!teamFilter || team == -1 || team == g_loadouts[loadout][LoadoutTeam])
				)
			{
				ids[count] = g_loadouts[loadout][LoadoutId];
				count++;
			}
		}
		
		Call_StartFunction(plugin, Function:callback);
		Call_PushArray(ids, count);
		Call_PushCell(count);
		Call_PushCell(data);
		Call_Finish();
	}
	else
	{
		new Handle:pack = CreateDataPack();
		WritePackCell(pack, _:filter);
		WritePackCell(pack, _:callback);
		WritePackCell(pack, _:plugin);
		WritePackCell(pack, _:data);
	
		SQL_TQuery(g_hSQL, T_GetLoadoutsCallback, "SELECT id, display_name, game, class, team FROM store_loadouts", pack);
	}
}

public T_GetLoadoutsCallback(Handle:owner, Handle:hndl, const String:error[], any:pack)
{
	if (hndl == INVALID_HANDLE)
	{
		Store_LogError("SQL Error on GetLoadouts: %s", error);
		return;
	}
	
	ResetPack(pack);
	
	new Handle:filter = Handle:ReadPackCell(pack);
	new Store_GetItemsCallback:callback = Store_GetItemsCallback:ReadPackCell(pack);
	new Handle:plugin = Handle:ReadPackCell(pack);
	new arg = ReadPackCell(pack);
	
	CloseHandle(pack);
	
	g_loadoutCount = 0;
	
	while (SQL_FetchRow(hndl))
	{
		g_loadouts[g_loadoutCount][LoadoutId] = SQL_FetchInt(hndl, 0);
		SQL_FetchString(hndl, 1, g_loadouts[g_loadoutCount][LoadoutDisplayName], 64);
		SQL_FetchString(hndl, 2, g_loadouts[g_loadoutCount][LoadoutGame], 32);
		SQL_FetchString(hndl, 3, g_loadouts[g_loadoutCount][LoadoutClass], 32);
		
		if (SQL_IsFieldNull(hndl, 4))
			g_loadouts[g_loadoutCount][LoadoutTeam] = -1;
		else
			g_loadouts[g_loadoutCount][LoadoutTeam] = SQL_FetchInt(hndl, 4);
		
		g_loadoutCount++;
	}
	
	GetLoadouts(filter, callback, plugin, true, arg);
}

GetLoadoutIndex(id)
{
	for (new index = 0; index < g_loadoutCount; index++)
	{
		if (g_loadouts[index][LoadoutId] == id)
			return index;
	}
	
	return -1;
}

/**
* Retrieves items of a specific player in a specific category. 
*
* To use this method, you can provide a callback for when the items are loaded.
* The callback will provide an array of the items' IDs. You can then loop the array,
* and find info about each item using the Store_GetItem* methods.
* 
* The items returned by this method are grouped by the item's name. That means that 
* if a player has multiple items with the same name (the unique identifier of the item, NOT its 
* display name), then the array will only have one element of that item.
*
* To determine how many items the player has of the same name, the callback provides the
* itemCount[] array.
*
* To deremine whether or not an item is equipped in the loadout specified, the callback
* provides the equipped[] array.
*
* As with all other store-database methods, this method is completely asynchronous.
*
* @param accountId		    The account ID of the player, use Store_GetClientAccountID to convert a client index to account ID.
* @param categoryId        	The category of the items you want to retrieve.
* @param loadoutId         	The loadout which will be used to determine whether an item is equipped or not.
* @param callback		    A callback which will be called when the items are loaded.
* @param plugin				The plugin owner of the callback.
* @param data              	Extra data value to pass to the callback.
*
* @noreturn
*/
GetUserItems(accountId, categoryId, loadoutId, Store_GetUserItemsCallback:callback, Handle:plugin = INVALID_HANDLE, any:data = 0)
{
	new Handle:pack = CreateDataPack();
	WritePackCell(pack, accountId); // 0 
	WritePackCell(pack, categoryId); // 8
	WritePackCell(pack, loadoutId);	// 16
	WritePackCell(pack, _:callback); // 24
	WritePackCell(pack, _:plugin); // 32
	WritePackCell(pack, _:data); // 40
	
	if (g_itemCount == -1)
	{
		Store_LogWarning("Store_GetUserItems has been called before item loading.");
		GetItems(GetUserItemsLoadCallback, INVALID_HANDLE, -1, true, pack);
		
		return;
	}
	
	decl String:query[512];
	Format(query, sizeof(query), "SELECT item_id, EXISTS(SELECT * FROM store_users_items_loadouts WHERE store_users_items_loadouts.useritem_id = store_users_items.id AND store_users_items_loadouts.loadout_id = %d) AS equipped, COUNT(*) AS count FROM store_users_items INNER JOIN store_users ON store_users.id = store_users_items.user_id INNER JOIN store_items ON store_items.id = store_users_items.item_id WHERE store_users.auth = %d AND store_items.category_id = %d GROUP BY item_id", loadoutId, accountId, categoryId);
	
	SQL_TQuery(g_hSQL, T_GetUserItemsCallback, query, pack);
}

public GetUserItemsLoadCallback(ids[], count, any:pack)
{
	ResetPack(pack);
	
	new accountId = ReadPackCell(pack); 
	new categoryId = ReadPackCell(pack); 
	new loadoutId = ReadPackCell(pack); 
	new Store_GetUserItemsCallback:callback = Store_GetUserItemsCallback:ReadPackCell(pack); 
	new Handle:plugin = Handle:ReadPackCell(pack); 
	new arg = ReadPackCell(pack); 
	
	CloseHandle(pack);
	
	GetUserItems(accountId, categoryId, loadoutId, callback, plugin, arg);
}

public T_GetUserItemsCallback(Handle:owner, Handle:hndl, const String:error[], any:pack)
{
	if (hndl == INVALID_HANDLE)
	{
		Store_LogError("SQL Error on GetUserItems: %s", error);
		return;
	}
	
	SetPackPosition(pack, 16);	

	new loadoutId = ReadPackCell(pack);	
	new Store_GetUserItemsCallback:callback = Store_GetUserItemsCallback:ReadPackCell(pack);
	new Handle:plugin = Handle:ReadPackCell(pack);
	new arg = ReadPackCell(pack);
	
	CloseHandle(pack);
	
	new count = SQL_GetRowCount(hndl);

	new ids[count];
	new bool:equipped[count];
	new itemCount[count];
	
	new index = 0;
	while (SQL_FetchRow(hndl))
	{
		ids[index] = SQL_FetchInt(hndl, 0);
		equipped[index] = bool:SQL_FetchInt(hndl, 1);
		itemCount[index] = SQL_FetchInt(hndl, 2);
		
		index++;
	}
	
	Call_StartFunction(plugin, Function:callback);
	Call_PushArray(ids, count);
	Call_PushArray(equipped, count);
	Call_PushArray(itemCount, count);	
	Call_PushCell(count);
	Call_PushCell(loadoutId);
	Call_PushCell(_:arg);
	Call_Finish();
}

/**
* Retrieves the amount of credits that a player currently has.
*
* As with all other store-database methods, this method is completely asynchronous.
*
* @param accountId		    The account ID of the player, use Store_GetClientAccountID to convert a client index to account ID.
* @param callback		    A callback which will be called when the credits amount is loaded.
* @param plugin				The plugin owner of the callback.
* @param data              	Extra data value to pass to the callback.
*
* @noreturn
*/
GetCredits(accountId, Store_GetCreditsCallback:callback, Handle:plugin = INVALID_HANDLE, any:data = 0)
{
	new Handle:pack = CreateDataPack();
	WritePackCell(pack, _:callback);
	WritePackCell(pack, _:plugin);
	WritePackCell(pack, _:data);
		
	decl String:query[255];
	Format(query, sizeof(query), "SELECT credits FROM store_users WHERE auth = %d", accountId);

	SQL_TQuery(g_hSQL, T_GetCreditsCallback, query, pack, DBPrio_High);
}

public T_GetCreditsCallback(Handle:owner, Handle:hndl, const String:error[], any:pack)
{
	if (hndl == INVALID_HANDLE)
	{
		Store_LogError("SQL Error on GetCredits: %s", error);
		return;
	}
	
	ResetPack(pack);
	
	new Store_GetCreditsCallback:callback = Store_GetCreditsCallback:ReadPackCell(pack);
	new Handle:plugin = Handle:ReadPackCell(pack);
	new arg = ReadPackCell(pack);
	
	CloseHandle(pack);
	
	if (SQL_FetchRow(hndl))
	{
		Call_StartFunction(plugin, Function:callback);
		Call_PushCell(SQL_FetchInt(hndl, 0));
		Call_PushCell(_:arg);
		Call_Finish();	
	}
}

/**
* Buys an item for a player, using his credits.
* 
* To determine whether or not the process of buying that item was successful,
* use the 'success' parameter that is provided by the callback.
* A false value of that parameter probably means that the user didn't have enough credits.
*
* As with all other store-database methods, this method is completely asynchronous.
*
* @param accountId		    The account ID of the player, use Store_GetClientAccountID to convert a client index to account ID.
* @param itemId            	The ID of the item to buy.
* @param callback		    A callback which will be called when the operation is finished.
* @param plugin				The plugin owner of the callback.
* @param data              	Extra data value to pass to the callback.
*
* @noreturn
*/
BuyItem(accountId, itemId, Store_BuyItemCallback:callback, Handle:plugin = INVALID_HANDLE, any:data = 0)
{
	new Handle:pack = CreateDataPack();
	WritePackCell(pack, itemId); // 0
	WritePackCell(pack, accountId); // 8
	WritePackCell(pack, _:callback); // 16
	WritePackCell(pack, _:plugin); // 24
	WritePackCell(pack, _:data); // 32
	
	GetCredits(accountId, T_BuyItemGetCreditsCallback, INVALID_HANDLE, pack);
}

public T_BuyItemGetCreditsCallback(credits, any:pack)
{
	ResetPack(pack);
	
	new itemId = ReadPackCell(pack); 
	new accountId = ReadPackCell(pack); 
	new Store_BuyItemCallback:callback = Store_BuyItemCallback:ReadPackCell(pack); 
	new Handle:plugin = Handle:ReadPackCell(pack);
	new arg = ReadPackCell(pack);
	
	if (credits < g_items[GetItemIndex(itemId)][ItemPrice])
	{
		Call_StartFunction(plugin, Function:callback);
		Call_PushCell(0);
		Call_PushCell(_:arg);
		Call_Finish();	
		
		return;
	}

	GiveCredits(accountId, -g_items[GetItemIndex(itemId)][ItemPrice], T_BuyItemGiveCreditsCallback, _, pack);
}

public T_BuyItemGiveCreditsCallback(accountId, any:pack)
{
	ResetPack(pack);
	
	new itemId = ReadPackCell(pack);
	
	decl String:query[255];
	Format(query, sizeof(query), "INSERT INTO store_users_items (user_id, item_id) SELECT store_users.id AS userId, '%d' AS item_id FROM store_users WHERE auth = %d", itemId, accountId);

	SQL_TQuery(g_hSQL, T_BuyItemCallback, query, pack);	
}

public T_BuyItemCallback(Handle:owner, Handle:hndl, const String:error[], any:pack)
{
	if (hndl == INVALID_HANDLE)
	{
		Store_LogError("SQL Error on BuyItem: %s", error);
		return;
	}
	
	SetPackPosition(pack, 16);
	
	new Store_BuyItemCallback:callback = Store_BuyItemCallback:ReadPackCell(pack);
	new Handle:plugin = Handle:ReadPackCell(pack);
	new arg = ReadPackCell(pack);
	
	CloseHandle(pack);
	
	Call_StartFunction(plugin, Function:callback);
	Call_PushCell(1);
	Call_PushCell(_:arg);
	Call_Finish();	
}

/**
* Uses an item for a player (deletes one 'copy' of the item from his inventory.)
* 
* As with all other store-database methods, this method is completely asynchronous.
*
* @param accountId		    The account ID of the player, use Store_GetClientAccountID to convert a client index to account ID.
* @param itemId            	The ID of the item to use.
* @param callback		    A callback which will be called when the operation is finished.
* @param plugin				The plugin owner of the callback.
* @param data              	Extra data value to pass to the callback.
*
* @noreturn
*/
UseItem(accountId, itemId, Store_UseItemCallback:callback, Handle:plugin = INVALID_HANDLE, any:data = 0)
{
	new Handle:pack = CreateDataPack();
	WritePackCell(pack, accountId);
	WritePackCell(pack, itemId);
	WritePackCell(pack, _:callback);
	WritePackCell(pack, _:plugin);
	WritePackCell(pack, _:data);
	
	decl String:query[255];
	Format(query, sizeof(query), "DELETE FROM store_users_items WHERE store_users_items.item_id = %d AND store_users_items.userId IN (SELECT store_users.id FROM store_users WHERE store_users.auth = %d) LIMIT 1", itemId, accountId);
	
	SQL_TQuery(g_hSQL, T_UseItemCallback, query, pack);	
}

public T_UseItemCallback(Handle:owner, Handle:hndl, const String:error[], any:pack)
{
	if (hndl == INVALID_HANDLE)
	{
		Store_LogError("SQL Error on UseItem: %s", error);
		return;
	}
	
	ResetPack(pack);
		
	new accountId = ReadPackCell(pack);
	new itemId = ReadPackCell(pack);
	new Store_UseItemCallback:callback = Store_UseItemCallback:ReadPackCell(pack);
	new Handle:plugin = Handle:ReadPackCell(pack);
	new arg = ReadPackCell(pack);
	
	CloseHandle(pack);
	
	Call_StartFunction(plugin, Function:callback);
	Call_PushCell(accountId);
	Call_PushCell(itemId);	
	Call_PushCell(_:arg);
	Call_Finish();	
}

/**
* Equips an item for a player in a loadout.
* 
* As with all other store-database methods, this method is completely asynchronous.
*
* @param accountId		    The account ID of the player, use Store_GetClientAccountID to convert a client index to account ID.
* @param itemId            	The ID of the item to equip.
* @param loadoutId         	The loadout to equip the item in.
* @param callback		    A callback which will be called when the operation is finished.
* @param plugin				The plugin owner of the callback.
* @param data              	Extra data value to pass to the callback.
*
* @noreturn
*/
EquipItem(accountId, itemId, loadoutId, Store_EquipItemCallback:callback, Handle:plugin = INVALID_HANDLE, any:data = 0)
{
	new Handle:pack = CreateDataPack();
	WritePackCell(pack, accountId);
	WritePackCell(pack, itemId);
	WritePackCell(pack, loadoutId);	
	WritePackCell(pack, _:callback);
	WritePackCell(pack, _:plugin);
	WritePackCell(pack, _:data);
	
	UnequipItem(accountId, itemId, loadoutId, EquipUnequipItemCallback, _, pack);
}

public EquipUnequipItemCallback(accountId, itemId, loadoutId, any:pack)
{
	decl String:query[255];
	Format(query, sizeof(query), "INSERT INTO store_users_items_loadouts (loadout_id, useritem_id) SELECT %d AS loadout_id, users_items.id FROM store_users_items INNER JOIN store_users ON store_users.id = store_users_items.user_id WHERE store_users.auth = %d AND store_users_items.item_id = %d LIMIT 1", loadoutId, accountId, itemId);
	
	SQL_TQuery(g_hSQL, T_EquipItemCallback, query, pack);	
}

public T_EquipItemCallback(Handle:owner, Handle:hndl, const String:error[], any:pack)
{
	if (hndl == INVALID_HANDLE)
	{
		Store_LogError("SQL Error on EquipItem: %s", error);
		return;
	}
	
	ResetPack(pack);
	
	new accountId = ReadPackCell(pack);
	new itemId = ReadPackCell(pack);
	new loadoutId = ReadPackCell(pack);
	new Store_GiveCreditsCallback:callback = Store_GiveCreditsCallback:ReadPackCell(pack);
	new Handle:plugin = Handle:ReadPackCell(pack);
	new arg = ReadPackCell(pack);
	
	CloseHandle(pack);
	
	Call_StartFunction(plugin, Function:callback);
	Call_PushCell(accountId);
	Call_PushCell(itemId);
	Call_PushCell(loadoutId);	
	Call_PushCell(_:arg);
	Call_Finish();	
}

/**
* Unequips an item for a player in a loadout.
* 
* As with all other store-database methods, this method is completely asynchronous.
*
* @param accountId		    The account ID of the player, use Store_GetClientAccountID to convert a client index to account ID.
* @param itemId            	The ID of the item to unequip.
* @param loadoutId         	The loadout to unequip the item in.
* @param callback		    A callback which will be called when the operation is finished.
* @param plugin				The plugin owner of the callback.
* @param data             	Extra data value to pass to the callback.
*
* @noreturn
*/
UnequipItem(accountId, itemId, loadoutId, Store_EquipItemCallback:callback, Handle:plugin = INVALID_HANDLE, any:data = 0)
{
	new Handle:pack = CreateDataPack();
	WritePackCell(pack, accountId);
	WritePackCell(pack, itemId);
	WritePackCell(pack, loadoutId);
	WritePackCell(pack, _:callback);
	WritePackCell(pack, _:plugin);
	WritePackCell(pack, _:data);
	
	decl String:query[512];
	Format(query, sizeof(query), "DELETE store_users_items_loadouts FROM store_users_items_loadouts INNER JOIN store_users_items ON store_users_items.id = users_items_loadouts.useritem_id INNER JOIN store_users ON store_users.id = store_users_items.user_id INNER JOIN store_items ON store_items.id = store_users_items.item_id WHERE store_users.auth = %d AND store_items.loadout_slot = (SELECT loadout_slot from store_items WHERE store_items.id = %d) AND store_users_items_loadouts.loadout_id = %d", accountId, itemId, loadoutId);
	
	SQL_TQuery(g_hSQL, T_UnequipItemCallback, query, pack);	
}

public T_UnequipItemCallback(Handle:owner, Handle:hndl, const String:error[], any:pack)
{
	if (hndl == INVALID_HANDLE)
	{
		Store_LogError("SQL Error on UnequipItem: %s", error);
		return;
	}
	
	ResetPack(pack);
	
	new accountId = ReadPackCell(pack);
	new itemId = ReadPackCell(pack);
	new loadoutId = ReadPackCell(pack);
	new Store_GiveCreditsCallback:callback = Store_GiveCreditsCallback:ReadPackCell(pack);
	new Handle:plugin = Handle:ReadPackCell(pack);
	new arg = ReadPackCell(pack);
	
	CloseHandle(pack);
	
	Call_StartFunction(plugin, Function:callback);
	Call_PushCell(accountId);
	Call_PushCell(itemId);
	Call_PushCell(loadoutId);
	Call_PushCell(_:arg);
	Call_Finish();	
}

/**
* Retrieves equipped items of a specific player in a specific type. 
*
* To use this method, you can provide a callback for when the items are loaded.
* The callback will provide an array of the items' IDs. You can then loop the array,
* and find info about each item using the Store_GetItem* methods.
* 
* The items returned by this method are grouped by the item's name. That means that 
* if a player has multiple items with the same name (the unique identifier of the item, NOT its 
* display name), then the array will only have one element of that item.
*
* To determine how many items the player has of the same name, the callback provides the
* itemCount[] array.
*
* To deremine whether or not an item is equipped in the loadout specified, the callback
* provides the equipped[] array.
*
* For a full example of a usage of this method, see the store-inventory module.
*
* As with all other store-database methods, this method is completely asynchronous.
*
* @param accountId		    The account ID of the player, use Store_GetClientAccountID to convert a client index to account ID.
* @param type              	The category of the items you want to retrieve.
* @param loadoutId         	The loadout which will be used to determine whether an item is equipped or not.
* @param callback		    A callback which will be called when the items are loaded.
* @param plugin				The plugin owner of the callback.
* @param data              	Extra data value to pass to the callback.
*
* @noreturn
*/
GetEquippedItemsByType(accountId, const String:type[], loadoutId, Store_GetItemsCallback:callback, Handle:plugin = INVALID_HANDLE, any:data = 0)
{
	new Handle:pack = CreateDataPack();
	WritePackCell(pack, _:callback);
	WritePackCell(pack, _:plugin);
	WritePackCell(pack, _:data);
	
	decl String:query[512];
	Format(query, sizeof(query), "SELECT store_items.id FROM store_users_items INNER JOIN store_items ON store_items.id = store_users_items.item_id INNER JOIN store_users ON store_users.id = store_users_items.user_id INNER JOIN store_users_items_loadouts ON store_users_items_loadouts.useritem_id = store_users_items.id WHERE store_users.auth = %d AND store_items.type = '%s' AND store_users_items_loadouts.loadout_id = %d", accountId, type, loadoutId);
	
	SQL_TQuery(g_hSQL, T_GetEquippedItemsByTypeCallback, query, pack);	
}

public T_GetEquippedItemsByTypeCallback(Handle:owner, Handle:hndl, const String:error[], any:pack)
{
	if (hndl == INVALID_HANDLE)
	{
		Store_LogError("SQL Error on GetEquippedItemsByType: %s", error);
		return;
	}
	
	ResetPack(pack);
	
	new Store_GetItemsCallback:callback = Store_GetItemsCallback:ReadPackCell(pack);
	new Handle:plugin = Handle:ReadPackCell(pack);
	new arg = ReadPackCell(pack);
	
	CloseHandle(pack);
	
	new count = SQL_GetRowCount(hndl);
	new ids[count];
	
	new index = 0;
	while (SQL_FetchRow(hndl))
	{
		ids[index] = SQL_FetchInt(hndl, 0)
		index++;
	}
	
	Call_StartFunction(plugin, Function:callback);
	Call_PushArray(ids, count);
	Call_PushCell(count);
	Call_PushCell(arg);
	Call_Finish();	
}

/**
* Gives a player a specific amount of credits. 
* 
* You can also set the credits parameter to a negative value to take credits
* from the player.
*
* As with all other store-database methods, this method is completely asynchronous.
*
* @param accountId		    The account ID of the player, use Store_GetClientAccountID to convert a client index to account ID.
* @param credits           	The amount of credits to give to the player.
* @param callback		    A callback which will be called when the operation is finished.
* @param plugin				The plugin owner of the callback.
* @param data              	Extra data value to pass to the callback.
*
* @noreturn
*/
GiveCredits(accountId, credits, Store_GiveCreditsCallback:callback, Handle:plugin = INVALID_HANDLE, any:data = 0)
{
	new Handle:pack = CreateDataPack();
	WritePackCell(pack, accountId);
	WritePackCell(pack, _:callback);
	WritePackCell(pack, _:plugin);
	WritePackCell(pack, _:data);
	
	decl String:query[255];
	Format(query, sizeof(query), "UPDATE store_users SET credits = credits + %d WHERE auth = %d", credits, accountId);

	SQL_TQuery(g_hSQL, T_GiveCreditsCallback, query, pack);	
}

public T_GiveCreditsCallback(Handle:owner, Handle:hndl, const String:error[], any:pack)
{
	if (hndl == INVALID_HANDLE)
	{
		Store_LogError("SQL Error on GiveCredits: %s", error);
		return;
	}
	
	ResetPack(pack);
	
	new accountId = ReadPackCell(pack);
	new Store_GiveCreditsCallback:callback = Store_GiveCreditsCallback:ReadPackCell(pack);
	new Handle:plugin = Handle:ReadPackCell(pack);
	new arg = ReadPackCell(pack);
	
	CloseHandle(pack);
	
	Call_StartFunction(plugin, Function:callback);
	Call_PushCell(accountId);
	Call_PushCell(_:arg);
	Call_Finish();	
}

/**
* Gives multiple players a specific amount of credits. 
* 
* You can also set the credits parameter to a negative value to take credits
* from the players.
*
* As with all other store-database methods, this method is completely asynchronous.
*
* @param accountIds	    	The account IDs of the players, use Store_GetClientAccountID to convert a client index to account ID.
* @param accountIdsLength  	Players count.
* @param credits           	The amount of credits to give to the players.
*
* @noreturn
*/
GiveCreditsToUsers(accountIds[], accountIdsLength, credits)
{
	decl String:query[2048];
	Format(query, sizeof(query), "UPDATE store_users SET credits = credits + %d WHERE auth IN (", credits);
	
	for (new i = 0; i < accountIdsLength; i++)
	{
		Format(query, sizeof(query), "%s%d", query, accountIds[i]);
		
		if (i < accountIdsLength - 1)
			Format(query, sizeof(query), "%s, ", query);			
	}

	Format(query, sizeof(query), "%s)", query);	
	
	SQL_TQuery(g_hSQL, T_EmptyCallback, query);	
}

ConnectSQL()
{
	if (g_hSQL != INVALID_HANDLE)
		CloseHandle(g_hSQL);
	
	g_hSQL = INVALID_HANDLE;

	if (SQL_CheckConfig("store"))
	{
		SQL_TConnect(T_ConnectSQLCallback, "store");
	}
	else
	{
		Store_LogError("No config entry found for 'store' in databases.cfg.");
	}
}

public T_ConnectSQLCallback(Handle:owner, Handle:hndl, const String:error[], any:data)
{
	if (g_reconnectCounter >= 5)
	{
		Store_LogError("PLUGIN STOPPED - Reason: reconnect counter reached max - PLUGIN STOPPED");
		return;
	}

	if (hndl == INVALID_HANDLE)
	{
		Store_LogError("Connection to SQL database has failed, Reason: %s", error);
		
		g_reconnectCounter++;
		ConnectSQL();

		return;
	}

	decl String:driver[16];
	SQL_GetDriverIdent(owner, driver, sizeof(driver));

	g_hSQL = CloneHandle(hndl);		
	
	if (StrEqual(driver, "mysql", false))
	{
		SQL_FastQuery(g_hSQL, "SET NAMES  'utf8'");
	}
	
	CloseHandle(hndl);
	
	Call_StartForward(g_dbInitializedForward);
	Call_Finish();
	
	g_reconnectCounter = 1;
}

public Native_Register(Handle:plugin, params)
{
	new String:name[64];
	GetNativeString(2, name, sizeof(name));    
	
	Register(GetNativeCell(1), name);
}

public Native_RegisterClient(Handle:plugin, params)
{
	RegisterClient(GetNativeCell(1));
}

public Native_GetCategories(Handle:plugin, params)
{
	new any:data = 0;
	
	if (params == 3)
		data = GetNativeCell(3);
		
	GetCategories(Store_GetItemsCallback:GetNativeCell(1), plugin, bool:GetNativeCell(2), data);
}

public Native_GetCategoryDisplayName(Handle:plugin, params)
{
	SetNativeString(2, g_categories[GetCategoryIndex(GetNativeCell(1))][CategoryDisplayName], GetNativeCell(3));
}

public Native_GetCategoryDescription(Handle:plugin, params)
{
	SetNativeString(2, g_categories[GetCategoryIndex(GetNativeCell(1))][CategoryDescription], GetNativeCell(3));
}

public Native_GetCategoryPluginRequired(Handle:plugin, params)
{
	SetNativeString(2, g_categories[GetCategoryIndex(GetNativeCell(1))][CategoryRequirePlugin], GetNativeCell(3));
}

public Native_GetItems(Handle:plugin, params)
{
	new any:data = 0;
	
	if (params == 4)
		data = GetNativeCell(4);
		
	GetItems(Store_GetItemsCallback:GetNativeCell(1), plugin, GetNativeCell(2), bool:GetNativeCell(3), data);
}

public Native_GetItemName(Handle:plugin, params)
{
	SetNativeString(2, g_items[GetItemIndex(GetNativeCell(1))][ItemName], GetNativeCell(3));
}

public Native_GetItemDisplayName(Handle:plugin, params)
{
	SetNativeString(2, g_items[GetItemIndex(GetNativeCell(1))][ItemDisplayName], GetNativeCell(3));
}

public Native_GetItemDescription(Handle:plugin, params)
{
	SetNativeString(2, g_items[GetItemIndex(GetNativeCell(1))][ItemDescription], GetNativeCell(3));
}

public Native_GetItemType(Handle:plugin, params)
{
	SetNativeString(2, g_items[GetItemIndex(GetNativeCell(1))][ItemType], GetNativeCell(3));
}

public Native_GetItemLoadoutSlot(Handle:plugin, params)
{
	SetNativeString(2, g_items[GetItemIndex(GetNativeCell(1))][ItemLoadoutSlot], GetNativeCell(3));
}

public Native_GetItemPrice(Handle:plugin, params)
{
	return g_items[GetItemIndex(GetNativeCell(1))][ItemPrice];
}

public Native_GetItemCategory(Handle:plugin, params)
{
	return g_items[GetItemIndex(GetNativeCell(1))][ItemCategoryId];
}

public Native_GetLoadouts(Handle:plugin, params)
{	
	new any:data = 0;    
	if (params == 4)
		data = GetNativeCell(4);
		
	GetLoadouts(Handle:GetNativeCell(1), Store_GetItemsCallback:GetNativeCell(2), plugin, bool:GetNativeCell(3), data);
}

public Native_GetLoadoutDisplayName(Handle:plugin, params)
{
	SetNativeString(2, g_loadouts[GetLoadoutIndex(GetNativeCell(1))][LoadoutDisplayName], GetNativeCell(3));
}

public Native_GetLoadoutGame(Handle:plugin, params)
{	
	SetNativeString(2, g_loadouts[GetLoadoutIndex(GetNativeCell(1))][LoadoutGame], GetNativeCell(3));
}

public Native_GetLoadoutClass(Handle:plugin, params)
{
	SetNativeString(2, g_loadouts[GetLoadoutIndex(GetNativeCell(1))][LoadoutClass], GetNativeCell(3));
}

public Native_GetLoadoutTeam(Handle:plugin, params)
{
	return g_loadouts[GetLoadoutIndex(GetNativeCell(1))][LoadoutTeam];
}

public Native_GetUserItems(Handle:plugin, params)
{
	new any:data = 0;
	if (params == 5)
		data = GetNativeCell(5);
		
	GetUserItems(GetNativeCell(1), GetNativeCell(2), GetNativeCell(3), Store_GetUserItemsCallback:GetNativeCell(4), plugin, data);    
}

public Native_GetCredits(Handle:plugin, params)
{
	new any:data = 0;
	if (params == 3)
		data = GetNativeCell(3);
		
	GetCredits(GetNativeCell(1), Store_GetCreditsCallback:GetNativeCell(2), plugin, data);    
}

public Native_BuyItem(Handle:plugin, params)
{	
	new any:data = 0;
	
	if (params == 4)
		data = GetNativeCell(4);

	BuyItem(GetNativeCell(1), GetNativeCell(2), Store_BuyItemCallback:GetNativeCell(3), plugin, data);
}

public Native_UseItem(Handle:plugin, params)
{
	new any:data = 0;
	
	if (params == 4)
		data = GetNativeCell(4);

	UseItem(GetNativeCell(1), GetNativeCell(2), Store_UseItemCallback:GetNativeCell(3), plugin, data);
}

public Native_EquipItem(Handle:plugin, params)
{
	new any:data = 0;
	
	if (params == 5)
		data = GetNativeCell(5);

	EquipItem(GetNativeCell(1), GetNativeCell(2), GetNativeCell(3), Store_EquipItemCallback:GetNativeCell(4), plugin, data);
}

public Native_UnequipItem(Handle:plugin, params)
{
	new any:data = 0;
	
	if (params == 5)
		data = GetNativeCell(5);

	UnequipItem(GetNativeCell(1), GetNativeCell(2), GetNativeCell(3), Store_EquipItemCallback:GetNativeCell(4), plugin, data);
}

public Native_GetEquippedItemsByType(Handle:plugin, params)
{	
	decl String:type[32];
	GetNativeString(2, type, sizeof(type)); 
	
	new any:data = 0;
	
	if (params == 5)
		data = GetNativeCell(5);

	GetEquippedItemsByType(GetNativeCell(1), type, GetNativeCell(3), Store_GetItemsCallback:GetNativeCell(4), plugin, data);
}

public Native_GiveCredits(Handle:plugin, params)
{
	new any:data = 0;
	
	if (params == 4)
		data = GetNativeCell(4);
		
	GiveCredits(GetNativeCell(1), GetNativeCell(2), Store_GiveCreditsCallback:GetNativeCell(3), plugin, data);
}

public Native_GiveCreditsToUsers(Handle:plugin, params)
{
	new length = GetNativeCell(2);
	
	new accountIds[length];
	GetNativeArray(1, accountIds, length);
	
	GiveCreditsToUsers(accountIds, length, GetNativeCell(3));
}