package com.spoon.backgroundFileUpload;

import android.content.Context;

import com.orm.SugarRecord;
import com.orm.dsl.Unique;
import com.orm.query.Condition;
import com.orm.query.Select;
import com.sromku.simple.storage.SimpleStorage;
import com.sromku.simple.storage.Storage;

import org.json.JSONObject;

import java.util.List;

public class PendingUpload extends SugarRecord {
    @Unique
    String uploadId;
    String data;
    private static Storage storage;
    private static String uploadDirectoryName = "FileTransferBackground";

    public PendingUpload() {

    }

    public PendingUpload(JSONObject payload) {
        try {
            uploadId = payload.getString("id");
            data = payload.toString();
        } catch (Exception e) {
            e.printStackTrace();
        }
    }

    public static void init(Context context) {
//        storage = SimpleStorage.getInternalStorage(context);
//        storage.createDirectory(uploadDirectoryName);
    }

    public static void create(JSONObject payload) {
        new PendingUpload(payload).save();
//        try {
//            upload.put("createdDate", System.currentTimeMillis() / 1000);
//            upload.put("state", UploadState.STARTED);
//            storage.createFile(uploadDirectoryName, upload.getString("id") + ".json", upload.toString());
//        } catch (Exception e) {
//            e.printStackTrace();
//        }
    }


    public static void remove(String uploadId) {
        try {
            List<PendingUpload> results = Select.from(PendingUpload.class)
                    .where(Condition.prop("uploadId").eq(uploadId))
                    .list();
            if (results.size() > 0)
                results.get(0).delete();
        } catch (Exception e) {
            e.printStackTrace();
        }
    }

    public static List<PendingUpload> all() {
        return PendingUpload.listAll(PendingUpload.class);
    }
}
